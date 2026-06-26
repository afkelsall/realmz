#!/usr/bin/env bash
#
# build-windows.sh — cross-compile Realmz for Windows (x86_64) from Linux/macOS
# using the llvm-mingw (Clang) toolchain.
#
# This is a from-scratch driver: it builds the three non-vendored dependencies
# (zlib, phosg, resource_dasm) into a prefix, then configures and builds Realmz
# and produces the Windows package (ZIP + NSIS installer) via CPack.
#
# By default it builds two exes: the normal Release Realmz.exe (packaged), and a
# Debug diagnostic Realmz-debug.exe (symbols + verbose logging + AddressSanitizer)
# dropped into the test folder for diagnosing crashes. Use --release-only to skip
# the Debug build (roughly halves the per-rebuild time).
#
# Quick start (Ubuntu):
#   sudo apt install -y cmake ninja-build git build-essential nsis
#   # download llvm-mingw-*-ucrt-ubuntu-*.tar.xz, extract to /opt/llvm-mingw
#   git submodule update --init --recursive
#   ./build-windows.sh
#
# Re-run after editing Realmz source: ./build-windows.sh --skip-deps
# Release exe only (faster):         ./build-windows.sh --skip-deps --release-only
#
set -euo pipefail

# ---- Configuration (override via environment) --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in <repo>/scripts; the repo root is one level up. Build
# artifacts, fetched dep sources, and the CMake source dir all hang off the root,
# while the toolchain file ships alongside this script in scripts/.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LLVM_MINGW_ROOT="${LLVM_MINGW_ROOT:-/opt/llvm-mingw}"
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-${SCRIPT_DIR}/TC-mingw.cmake}"
DEPS_PREFIX="${DEPS_PREFIX:-${HOME}/mingw-install}"   # where cross-built deps install
DEPS_SRC="${DEPS_SRC:-${REPO_ROOT}/.deps-src}"        # where dep sources get cloned
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build_win}"
# Separate build tree for the Debug diagnostic exe (Realmz-debug.exe). Built with
# debug symbols, the original code's verbose per-primitive logging, and
# AddressSanitizer, so a crash prints where and why it died. Skipped with
# --release-only.
DEBUG_BUILD_DIR="${DEBUG_BUILD_DIR:-${REPO_ROOT}/build_win_debug}"
# Default to Release: phosg::Image's per-pixel rendering loops are dramatically
# faster optimized, and Release drops the per-primitive debug logging. Override
# with BUILD_TYPE=Debug for local debugging.
BUILD_TYPE="${BUILD_TYPE:-Release}"
# Host-visible drop folder for finished artifacts (VirtualBox shared folder on
# this VM). The installer .exe and .zip are copied here under their stable CPack
# names, and the raw Realmz.exe is dropped into the matching extracted test
# folder (e.g. Realmz-8.1.0-win64/) so a rebuild is immediately runnable. Copy is
# skipped if the folder is absent, so the script stays portable; override or
# unset to point elsewhere.
SHARE_DIR="${REALMZ_SHARE_DIR:-/mnt/hgfs/SharedFolder}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# Pinned dependency commits — keep in sync with README.md "Building on Mac".
PHOSG_COMMIT="b2e0c12edb7e274a5e20c460f44eee44f49f57ef"
RESOURCE_DASM_COMMIT="27f64c89a5fed855e68c2a5e97b6c6c389d8eb19"
ZLIB_TAG="v1.3.1"

SKIP_DEPS=0
SKIP_DEBUG=0
for arg in "$@"; do
    case "$arg" in
        --skip-deps) SKIP_DEPS=1 ;;
        --release-only) SKIP_DEBUG=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 28
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

export LLVM_MINGW_ROOT
export PATH="${LLVM_MINGW_ROOT}/bin:${PATH}"

# Let the toolchain file add the deps prefix to the raw compiler/linker search
# paths (phosg includes <zlib.h> / links -lz without find_package — see TC-mingw.cmake).
export REALMZ_DEPS_PREFIX="${DEPS_PREFIX}"

CMAKE_DEP_ARGS=(
    -G Ninja
    -D CMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}"
    -D CMAKE_INSTALL_PREFIX="${DEPS_PREFIX}"
    -D CMAKE_PREFIX_PATH="${DEPS_PREFIX}"
    -D CMAKE_BUILD_TYPE="${BUILD_TYPE}"
)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Write a Windows double-click launcher (.bat, CRLF) that captures all output to
# a timestamped log and pauses on exit so a crash stays readable on screen.
write_launcher() {  # dest exe stem extra_env_line
    local dest="$1" exe="$2" stem="$3" extra="$4"
    {
        printf '@echo off\n'
        printf 'setlocal\n'
        printf 'cd /d "%%~dp0"\n'
        [ -n "${extra}" ] && printf '%s\n' "${extra}"
        printf "for /f %%%%i in ('powershell -NoProfile -Command \"Get-Date -Format yyyyMMdd-HHmmss\"') do set STAMP=%%%%i\n"
        printf 'set LOG=%s-%%STAMP%%.log\n' "${stem}"
        printf 'echo Launching %s\n' "${exe}"
        printf 'echo Output is being saved to %%LOG%%\n'
        printf 'echo This window stays open after the game exits so you can read any error.\n'
        printf 'echo.\n'
        printf '%s > "%%LOG%%" 2>&1\n' "${exe}"
        printf 'echo.\n'
        printf 'echo ============================================================\n'
        printf 'echo %s exited with code %%ERRORLEVEL%%.\n' "${exe}"
        printf 'echo Full output saved to: %%CD%%\\%%LOG%%\n'
        printf 'echo ============================================================\n'
        printf 'pause\n'
        printf 'endlocal\n'
    } | sed 's/$/\r/' > "${dest}"
    log "Wrote $(basename "${dest}")"
}

# ---- Sanity checks -----------------------------------------------------------
[ -x "${LLVM_MINGW_ROOT}/bin/x86_64-w64-mingw32-clang" ] || {
    echo "ERROR: llvm-mingw not found at ${LLVM_MINGW_ROOT}" >&2
    echo "Download from https://github.com/mstorsjo/llvm-mingw/releases and" >&2
    echo "extract it there, or set LLVM_MINGW_ROOT." >&2
    exit 1
}

if [ ! -e "${REPO_ROOT}/vendored/SDL/CMakeLists.txt" ]; then
    log "Initializing git submodules (SDL, SDL_ttf, SDL_image)"
    git -C "${REPO_ROOT}" submodule update --init --recursive
fi

if [ -f "${REPO_ROOT}/vendored/SDL_ttf/external/download.sh" ] \
   && [ ! -d "${REPO_ROOT}/vendored/SDL_ttf/external/freetype/include" ]; then
    log "Downloading SDL_ttf external dependencies (freetype, etc.)"
    ( cd "${REPO_ROOT}/vendored/SDL_ttf/external" && ./download.sh )
fi

# ---- Build cross-compiled dependencies ---------------------------------------
clone_at() {  # url commit dest
    local url="$1" commit="$2" dest="$3"
    if [ ! -d "${dest}/.git" ]; then
        git clone "${url}" "${dest}"
    fi
    git -C "${dest}" fetch --depth 1 origin "${commit}" 2>/dev/null || git -C "${dest}" fetch origin
    git -C "${dest}" checkout --quiet "${commit}"
    git -C "${dest}" submodule update --init --recursive 2>/dev/null || true
}

build_dep() {  # name src extra_cmake_args...
    local name="$1" src="$2"; shift 2
    log "Building dependency: ${name}"
    cmake -S "${src}" -B "${src}/build_win" "${CMAKE_DEP_ARGS[@]}" "$@"
    cmake --build "${src}/build_win" --parallel "${JOBS}"
    cmake --install "${src}/build_win"
}

if [ "${SKIP_DEPS}" -eq 0 ]; then
    mkdir -p "${DEPS_SRC}" "${DEPS_PREFIX}"

    clone_at https://github.com/madler/zlib.git            "${ZLIB_TAG}"             "${DEPS_SRC}/zlib"
    clone_at https://github.com/fuzziqersoftware/phosg.git "${PHOSG_COMMIT}"         "${DEPS_SRC}/phosg"
    clone_at https://github.com/fuzziqersoftware/resource_dasm.git "${RESOURCE_DASM_COMMIT}" "${DEPS_SRC}/resource_dasm"

    build_dep zlib          "${DEPS_SRC}/zlib"
    # phosg/resource_dasm/Realmz link plain `-lz`, but zlib's CMake installs under
    # the `zlib` name (libzlib.dll[.a] / libzlibstatic.a). Provide the conventional
    # `z` name as the STATIC lib only, and remove the shared library + its import
    # lib: MinGW's linker prefers an import lib (.dll.a) over the static (.a) for a
    # given -l name, which would make Realmz.exe depend on libzlib.dll at runtime
    # (a DLL we don't bundle). Forcing static keeps zlib self-contained in the exe.
    [ -f "${DEPS_PREFIX}/lib/libzlibstatic.a" ] && cp -f "${DEPS_PREFIX}/lib/libzlibstatic.a" "${DEPS_PREFIX}/lib/libz.a"
    rm -f "${DEPS_PREFIX}/lib/libz.dll.a" \
          "${DEPS_PREFIX}/lib/libzlib.dll.a" \
          "${DEPS_PREFIX}/bin/libzlib.dll"

    build_dep phosg         "${DEPS_SRC}/phosg"          -D BUILD_TESTING=OFF
    build_dep resource_dasm "${DEPS_SRC}/resource_dasm"  -D BUILD_TESTING=OFF
else
    log "Skipping dependency build (--skip-deps)"
fi

# ---- Configure & build Realmz ------------------------------------------------
log "Configuring Realmz"
cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
    -G Ninja \
    -D CMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -D CMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
    -D CMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -D SDLTTF_VENDORED=ON

log "Building Realmz + package"
cmake --build "${BUILD_DIR}" --target package --parallel "${JOBS}"

# ---- Configure & build the Debug diagnostic exe ------------------------------
# Separate build tree, forced CMAKE_BUILD_TYPE=Debug so it keeps symbols, the
# original code's verbose logging, and AddressSanitizer (see CMakeLists.txt). We
# build only the Realmz target, not the package: the raw exe is dropped next to
# the Release one in the test folder as Realmz-debug.exe.
if [ "${SKIP_DEBUG}" -eq 0 ]; then
    log "Configuring Realmz (Debug diagnostic build)"
    cmake -S "${REPO_ROOT}" -B "${DEBUG_BUILD_DIR}" \
        -G Ninja \
        -D CMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
        -D CMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
        -D CMAKE_BUILD_TYPE=Debug \
        -D SDLTTF_VENDORED=ON

    log "Building Realmz (Debug diagnostic build)"
    cmake --build "${DEBUG_BUILD_DIR}" --target Realmz --parallel "${JOBS}"
else
    log "Skipping Debug diagnostic build (--release-only)"
fi

log "Done. Artifacts in ${BUILD_DIR}:"
ls -1 "${BUILD_DIR}"/Realmz-*.{exe,zip} 2>/dev/null || ls -1 "${BUILD_DIR}"/*.exe "${BUILD_DIR}"/*.zip 2>/dev/null || true

# ---- Copy artifacts to the host-visible shared folder, if mounted -----------
# Drop the installer .exe and .zip under their stable CPack names (overwriting),
# and refresh the raw Realmz.exe inside the matching extracted test folder.
if [ -d "${SHARE_DIR}" ]; then
    log "Copying artifacts to ${SHARE_DIR}"
    cp -f "${BUILD_DIR}"/Realmz-*.exe "${BUILD_DIR}"/Realmz-*.zip "${SHARE_DIR}/" 2>/dev/null || true

    # The test folder name matches the zip basename (e.g. Realmz-8.1.0-win64),
    # so it tracks the version automatically. Realmz-*.exe above is the installer;
    # build_win/Realmz.exe is the raw game binary the test folder runs.
    ZIP="$(ls -1 "${BUILD_DIR}"/Realmz-*.zip 2>/dev/null | head -n1)"
    if [ -n "${ZIP}" ]; then
        TESTDIR="${SHARE_DIR}/$(basename "${ZIP}" .zip)"
        if [ -d "${TESTDIR}" ] && [ -f "${BUILD_DIR}/Realmz.exe" ]; then
            cp -f "${BUILD_DIR}/Realmz.exe" "${TESTDIR}/Realmz.exe"
            log "Updated ${TESTDIR}/Realmz.exe"

            # Drop the Debug diagnostic exe alongside it. It reuses the DLLs the
            # Release package already bundled into the test folder (SDL*, libc++,
            # libunwind, and the asan runtime), so the bare exe is enough.
            if [ "${SKIP_DEBUG}" -eq 0 ] && [ -f "${DEBUG_BUILD_DIR}/Realmz.exe" ]; then
                cp -f "${DEBUG_BUILD_DIR}/Realmz.exe" "${TESTDIR}/Realmz-debug.exe"
                log "Updated ${TESTDIR}/Realmz-debug.exe"
            fi

            # Write the double-click launchers that log to a timestamped file and
            # keep the console open after the game exits (so a crash is readable).
            write_launcher "${TESTDIR}/Run Realmz (logged).bat" "Realmz.exe" "Realmz" ""
            if [ "${SKIP_DEBUG}" -eq 0 ]; then
                write_launcher "${TESTDIR}/Run Realmz Debug (logged).bat" "Realmz-debug.exe" "Realmz-debug" \
                    "set ASAN_OPTIONS=abort_on_error=0:halt_on_error=1:print_stats=1:symbolize=1"
            fi
        elif [ ! -d "${TESTDIR}" ]; then
            log "Test folder ${TESTDIR} not present; skipped Realmz.exe drop"
        fi
    fi
else
    log "Shared folder ${SHARE_DIR} not present; skipping artifact copy (set REALMZ_SHARE_DIR to enable)"
fi
