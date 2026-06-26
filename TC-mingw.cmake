# Toolchain file for cross-compiling Realmz to Windows (x86_64) from Linux/macOS
# using the llvm-mingw (Clang-based MinGW) toolchain.
#
# Clang is REQUIRED, not optional: the build passes -fpascal-strings, which MSVC
# and mainline MinGW-GCC do not support. llvm-mingw is Clang under the hood.
#
# Usage:
#   cmake -B build_win -DCMAKE_TOOLCHAIN_FILE=/abs/path/TC-mingw.cmake ...
#
# Point the toolchain at your llvm-mingw install with either:
#   - the LLVM_MINGW_ROOT environment variable, or
#   - -DLLVM_MINGW_ROOT=/opt/llvm-mingw on the cmake command line
# Defaults to /opt/llvm-mingw (matches build-windows.sh).

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Resolve the llvm-mingw root: cache var > env var > default.
if(NOT LLVM_MINGW_ROOT)
    if(DEFINED ENV{LLVM_MINGW_ROOT})
        set(LLVM_MINGW_ROOT "$ENV{LLVM_MINGW_ROOT}")
    else()
        set(LLVM_MINGW_ROOT "/opt/llvm-mingw")
    endif()
endif()

if(NOT EXISTS "${LLVM_MINGW_ROOT}")
    message(FATAL_ERROR
        "llvm-mingw not found at '${LLVM_MINGW_ROOT}'. "
        "Set -DLLVM_MINGW_ROOT=/path/to/llvm-mingw or the LLVM_MINGW_ROOT env var.")
endif()

set(TARGET_TRIPLE x86_64-w64-mingw32)

set(CMAKE_C_COMPILER   "${LLVM_MINGW_ROOT}/bin/${TARGET_TRIPLE}-clang")
set(CMAKE_CXX_COMPILER "${LLVM_MINGW_ROOT}/bin/${TARGET_TRIPLE}-clang++")
set(CMAKE_RC_COMPILER  "${LLVM_MINGW_ROOT}/bin/${TARGET_TRIPLE}-windres")
set(CMAKE_AR           "${LLVM_MINGW_ROOT}/bin/llvm-ar")
set(CMAKE_RANLIB       "${LLVM_MINGW_ROOT}/bin/llvm-ranlib")

# Where to look for headers/libs of cross-built dependencies (phosg, resource_dasm, zlib).
# CMAKE_PREFIX_PATH passed on the command line is appended to this automatically.
set(CMAKE_FIND_ROOT_PATH "${LLVM_MINGW_ROOT}/${TARGET_TRIPLE}")

# Add the deps prefix to raw compiler/linker search paths. Phosg includes
# <zlib.h> and links -lz without find_package, so we have to inject the path
# at the flags level rather than relying on CMAKE_PREFIX_PATH alone.
if(DEFINED ENV{REALMZ_DEPS_PREFIX})
    set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   -I$ENV{REALMZ_DEPS_PREFIX}/include")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -I$ENV{REALMZ_DEPS_PREFIX}/include")
    set(CMAKE_EXE_LINKER_FLAGS    "${CMAKE_EXE_LINKER_FLAGS}    -L$ENV{REALMZ_DEPS_PREFIX}/lib")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -L$ENV{REALMZ_DEPS_PREFIX}/lib")
endif()

# Find programs on the host, but headers/libs/packages only in the target sysroot + prefixes.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
