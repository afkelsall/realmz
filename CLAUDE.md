# Realmz - Agent Guide

Orientation for an agent starting a fresh session. Read this before investigating or
changing code; it captures the non-obvious context that the folder tree alone won't tell you.

## What this is

Realmz is a classic turn-based RPG, originally written for **early-1990s Macintosh** (System
7 / Classic Mac OS) in C, released 1994. This repo is a **port to modern systems** that keeps
the original game logic essentially intact and re-implements the Mac platform underneath it on
top of **SDL3**. Targets are **macOS and Windows only** - there is no native Linux runtime
target (see "Platform branches" below). License is CC BY-NC-SA 4.0; treat game assets and
source as non-commercial.

## The one architectural idea that explains everything

The codebase is **two layers**, and almost every "why is it written like this?" question
resolves once you know which layer you're in:

1. **`src/realmz_orig/` - the original 1994 game.** ~200 `.c` files of C90 gameplay logic
   (combat, spells, monsters, map, character data). It calls **Classic Mac Toolbox** APIs
   (QuickDraw, Window/Menu/Resource/Sound Managers) and uses **Pascal strings**. Treat this as
   legacy code: preserve behavior, change it only with strong reason, and expect terse 1990s
   style. Bugs fixed here are usually faithfulness-to-original or alignment/endianness issues.

2. **`src/` (top level) - the compatibility shim.** Modern C++ that **re-implements the Mac
   Toolbox on SDL3** so the original code can run unchanged. The big ones: `QuickDraw`,
   `WindowManager`, `MenuManager`, `ResourceManager`, `EventManager`, `SoundManager`,
   `FileManager`, `MemoryManager`, `Font`. `Types.h` defines the Classic Mac types (`Rect`,
   `Handle`, `OSErr`, `Boolean`, `Str255`, ...). `RealmzCocoa.c` is C glue between the two layers
   (the name is historical - it is not macOS-specific). When original code "calls the Mac OS,"
   it lands here.

**Practical consequence:** a rendering/menu/sound/file/resource bug is almost always a shim bug
in `src/`; a rules/combat/data bug is almost always in `src/realmz_orig/`. Decide which layer
owns the behavior before you start reading.

### Resource forks and game data

Game data lives in Classic Mac **resource-fork** files (`*.rsrc`, plus the `Data *` files under
`base/Realmz/Data Files/` and scenario folders). These are parsed by **resource_dasm**
(`resource_file` package) with **phosg** as its utility dependency - both are external, pinned
deps, not vendored. When something reads game content (portraits, tacticals, scenario data),
the path runs through `ResourceManager` -> `resource_file`. Multi-byte fields are big-endian Mac
data, so **byte order and struct alignment matter** - a whole class of historical bug fixes are
misaligned/wrong-endianness reads.

When asked about a specific item's real stats (magic plus, to-hit, damage, AC, or what an item
actually does versus what its name claims), read **`agent/docs/item-data.md`** first. It
documents the item data model (`struct itemattr`, the `all*` tables, where stats vs names live)
and gives a repeatable recipe for reading raw values straight out of `base/Realmz/Data Files/Data
ID`, plus the key gotcha that an item's printed "+N" name is an independent string and need not
match its real `item.damage` plus.

When asked why a spell behaves a certain way, what a spell's real parameters are, or what a
monster's stats are (magic resistance, saves, immunities, HD), read
**`agent/docs/spell-monster-data.md`** first. It documents the on-disk layout of `struct spell`
(`Data S`) and `struct monster` (the `Data MD` family), the lookup quirks (spell `spelldata`
caste index is class minus 1; monsters are found by the `monname` anchor), the byte-order rules,
and a repeatable recipe for reading raw values. It also records the `spellimmune[6]` out-of-bounds
read that made class 6 spells (Cosmic Blast) always resisted.

### Platform branches

`CMakeLists.txt` has `if(APPLE) ... elseif(WIN32) ...` with **no Linux branch**. macOS adds
`src/macos/MenuController.mm` (Cocoa); Windows adds `src/windows/MenuController.cpp` +
`WinMenuController.cpp` and links `bcrypt`. A plain Linux build has no `MenuController` and
won't link - so on Linux the only supported output is a **cross-compiled Windows build**.

## Building for Windows (from Linux or macOS)

The toolchain is **non-negotiable: llvm-mingw (Clang)**. The build passes `-fpascal-strings`,
which **MSVC and mainline MinGW-GCC reject** - only Clang accepts it. So MSVC/Visual Studio and
CLion's default GCC toolchain do not work without removing that flag.

Cross-compile is automated by **`scripts/build-windows.sh`** + **`scripts/TC-mingw.cmake`**:

```bash
# Ubuntu host, one-time:
sudo apt install -y cmake ninja-build git build-essential nsis
# download llvm-mingw-*-ucrt-ubuntu-*.tar.xz, extract to /opt/llvm-mingw (or set LLVM_MINGW_ROOT)
git submodule update --init --recursive

./scripts/build-windows.sh              # builds zlib + phosg + resource_dasm, then Realmz + installer
./scripts/build-windows.sh --skip-deps  # fast re-build after editing Realmz source only
```

What the script does, in order: inits submodules -> fetches SDL_ttf externals
(`vendored/SDL_ttf/external/download.sh`) -> cross-builds the three external deps (zlib,
**phosg @ `b2e0c12`**, **resource_dasm @ `27f64c89`** - commits pinned in the script, keep in
sync with README) into `~/mingw-install` -> configures Realmz with the toolchain file and
`-DSDLTTF_VENDORED=ON` -> builds the `package` target. Output (`.exe` installer + `.zip`) lands
in `build_win/`.

Key knobs (env vars): `LLVM_MINGW_ROOT`, `DEPS_PREFIX`, `BUILD_DIR`, `BUILD_TYPE`. The CMake
file already handles the Windows specifics - `bcrypt`, `PHOSG_WINDOWS=1`, and bundling the
llvm-mingw runtime DLLs (`libc++`, `libunwind`, asan) alongside the exe.

There is **no native-Windows or CLion build documented or wired up.** If asked to support it,
the blocker to solve first is `-fpascal-strings` (provide a Clang toolchain or scope out the
flag), not CMake plumbing.

> macOS-native and Mac->Windows builds are also covered in `README.md`; SDL/SDL_ttf/SDL_image
> are git submodules under `vendored/`.

### Integration branch + test release (one command)

`scripts/rebuild-integration.sh` rebuilds the **local-only, disposable** `integration` branch
and produces a Windows test release in one step. These scripts and `scripts/integration.txt`
are not part of the Realmz repo: they live in the separate `gitl` overlay repo (see "Local-only
files" below), so they never appear in a Realmz feature branch or PR. The `integration` branch
itself is recreated from scratch each run, so never open a PR from it.

```bash
./scripts/rebuild-integration.sh              # merge branches from integration.txt, then build + copy
./scripts/rebuild-integration.sh --no-build   # merge only, skip the Windows build
```

What it does: refreshes `main` from `origin`, deletes and recreates `integration`, then merges
each branch listed in **`scripts/integration.txt`** (one per line; `#` comments and blank lines
ignored) **sequentially**, so git **rerere** can replay a recorded resolution for a known
conflict and the script auto-commits the merge. If a conflict has no recorded resolution it
stops with the merge in progress - resolve it, `git commit`, then re-run; your commit teaches
rerere, so the next run resolves it automatically. After a clean merge it runs
`scripts/build-windows.sh --skip-deps`, which copies the `.exe` installer + `.zip` into the
shared folder (`/mnt/mahd`, override with `REALMZ_SHARE_DIR`) and drops the raw `Realmz.exe`
into the extracted test folder there (`Realmz-8.1.0-win64/`, name derived from the zip) so it
is immediately runnable.

To change what goes into the test release, edit `scripts/integration.txt` - that is the single
source of truth for the branch list. **When you create a feature branch that should be tested in
the next build, add its name to `scripts/integration.txt`** and commit that to the `gitl`
overlay (not the Realmz repo). Drop a branch from the list once it has merged to `main`.

**Branch notes:** `branches.md` (repo root, also in the `gitl` overlay) lists local branches
that should be excluded when auditing what is and isn't merged or has an open PR -- research
branches, disposable branches, and tracking branches that are not feature work.

### Local-only files (the `gitl` overlay repo)

Developer-local files (this `CLAUDE.md`, `scripts/`, `branches.md`, `agent/`) are tracked in a
**separate git repo overlaid on the same working tree**, not in the Realmz repo, so they can
never leak into a Realmz branch or PR. Drive that repo with the `gitl` alias instead of `git`.
Full details, including the rule for when something belongs in the overlay versus a real Realmz
branch, are in **`agent/docs/local-overlay.md`** - read it before adding, moving, or committing
any of these files.

## Conventions & gotchas for changes

- **Match the layer's style.** Don't modernize `src/realmz_orig/` C90 for taste; do write
  normal modern C++ in `src/`.
- **Pascal strings** are real here (`-fpascal-strings`, `Str255`). A `"\p..."` literal is a
  Pascal string (length-prefixed), not a C string. Don't "fix" them.
- **Endianness/alignment:** when touching resource parsing or struct layout, assume big-endian
  source data and verify field offsets - this is the most common historical bug class.
- **Tag every change to original code.** Whenever you change behavior in `src/realmz_orig/` (or
  in any file that ports original code), wrap the change in the standard markers so it stays
  easy to diff against the 1994 source:

  ```c
  /* *** CHANGED FROM ORIGINAL IMPLEMENTATION ***
   * what changed and why */
  ...changed code...
  /* *** END CHANGES *** */
  ```

  Keep the marker adjacent to the code it describes. A small single-statement change may use the
  header-only form (the `CHANGED FROM ORIGINAL IMPLEMENTATION` comment with no `END CHANGES`),
  but prefer the full bracketed form for anything spanning more than one statement. Search
  "CHANGED FROM ORIGINAL IMPLEMENTATION" in the source for examples.
- **Don't bump the pinned dep commits casually** - phosg / resource_dasm are pinned in both
  `README.md` and `build-windows.sh`; the codebase tracks specific APIs.
- **User data / saves** live at `%AppData%\Fantasoft\Realmz` (Windows) and
  `~/Library/Application Support/Fantasoft/Realmz` (macOS). Saves can corrupt across changes -
  flag risk when touching save/load (`loadsavedgame.c`, `FileManager`).
- **Verify which layer owns a symbol before editing.** Many Toolbox-looking calls are shimmed
  in `src/`; grep there first rather than assuming a system header.
- **Do not hand-edit `CHANGELOG.md`.** It is generated from the changelist GitHub produces on a
  new release. Do not add "Unreleased" sections or per-PR entries; a maintainer will ask for
  manual entries to be removed (this happened on PR #241). Put the rationale for a deviation
  inline in the source with the "CHANGED FROM ORIGINAL IMPLEMENTATION" marker instead.

## Working with the upstream repo and the public (read before any outward action)

This is a community project and some contributors have strong feelings about AI being used
on it. Treat every artifact that can become public (commits, branches pushed to a remote, PR
titles/bodies, PR/issue comments, anything in the upstream repo) as something a skeptical human
will read. The cost of a visible AI "tell" here is reputational, so err heavily on the side of
caution. When in doubt, stop and ask the maintainer of this checkout before acting.

### No agentic markers, ever, in repo-facing or public text

Hard rule: never leave an AI marker in code, in comments, in commit messages, or in PR
titles/descriptions. The same rule also covers branch names, PR/issue comments, and CHANGELOG
entries. An "AI marker" is any trailer, footer, attribution, or punctuation tell that signals the
text was machine generated (see the specifics below). Check for them before every push.

- No `Co-Authored-By: Claude` (or any Anthropic/Claude) trailer on commits. Do not add it here,
  even though it is a default elsewhere. This repo overrides that default.
- No "Generated with Claude Code" or similar footer on PRs.
- No em dashes. Use a plain ASCII hyphen, a comma, or two sentences instead. Also avoid other
  non-ASCII "smart" punctuation that signals generated text: curly quotes, the ellipsis glyph,
  non-breaking spaces. Keep prose ASCII.
- No references to agent-only files. Never cite `AGENTS.md`, `CLAUDE.md`, `docs/*-spec.md`,
  plans, or "the spec" in committed code, comments, or messages. Those files are not in the
  repo and the reference is itself a tell.
- Match the surrounding comment style. Existing `src/` comments are ASCII only; keep yours the
  same so a new comment is indistinguishable from the existing ones.
- Before committing or pushing, scan the diff and messages for the above. A quick check:
  `git log <base>..HEAD --format='%B' | grep -nP '[\x{2014}\x{2013}\x{2018}\x{2019}\x{201C}\x{201D}\x{2026}]'`
  for punctuation, and `grep -niE 'claude|anthropic|co-authored'` for trailers. Both should be
  empty.

### Commit messages

- Imperative, concise subject line (for example "Fix non-functional volume/speed menus on
  Windows"). Blank line, then a plain-prose body explaining what changed and why.
- No trailers and no AI markers (see above). Hyphenated words like "non-functional" are fine;
  the concern is decorative em dashes and generated-text punctuation, not normal hyphens.
- Note deliberate divergence from the 1994 behavior with the existing "CHANGED FROM ORIGINAL
  IMPLEMENTATION" convention. Do not add CHANGELOG.md entries by hand; that file is generated
  from the release changelist (see the CHANGELOG note above).

### How to open a PR in this repo

- `git user` for this checkout does not have write access to upstream `Realmz-Castle/realmz`.
  Use the fork workflow. The fork is `afkelsall/realmz`, wired up as a git remote. Push the
  branch to the fork, then open the PR against `Realmz-Castle/realmz` `main` with the `gh` CLI
  (installed and authenticated as `afkelsall`).
- Before opening anything, list open PRs and issues and check for overlap
  (`gh pr list`, `gh issue list`). If a maintainer already has an open PR for the same area, do
  not open a competing one. Stack your change on their branch or hold it, and tell the user.
- Link related work: use `Closes #N` for the issue a PR resolves, and reference related PRs or
  issues by number so GitHub cross-links them.
- One logical change per PR. For a stacked change, base the branch on its dependency and say so;
  it can only become a clean PR once the dependency lands on `main`.
- Never push to `main`. Branch first.

### PR description style

Open with one plain sentence naming the user-visible symptom or goal. Then two short sections
with brief dot points:

- `Why:` what was wrong or needed, and the underlying cause. A few short points.
- `How:` what the change does to fix it. A few short points. When relevant, finish with one
  point noting it stays macOS/Windows compatible.

Keep each point to a single short line of plain prose. Use a plain ASCII hyphen for the bullet
marker (never an em dash or other smart punctuation). No testing steps, checklists, or
checkboxes. No AI markers. Keep the whole thing to what a maintainer needs to review the change.

A few more rules for these descriptions (and for issues):

- Wrap code in backticks. Function and variable names, struct fields, file paths, and small
  expressions (`centerfield`, `bq[tempicon]`, `t < maxloop`, `char[maxloop]`) all go in
  backticks so they render as code, not prose.
- Put everything a reviewer needs in the description itself. Do not add a separate PR comment to
  carry context the description should hold; if asked to add or change a note, edit the
  description (via the REST API if `gh pr edit` fails on this repo's deprecated Projects call).
- Classify the bug in the `Why:` points. Say whether it lives in the original game logic
  (`src/realmz_orig/`) or the SDL compatibility shim (`src/`), and whether it is platform
  specific (macOS vs Windows) or the same defect on every target that only happens to surface on
  one. State it plainly rather than leaving the maintainer to guess.

Example shape (PR #249, "Clip party roster stat numbers to their boxes"):

```
The party roster stat numbers can leave stray pixels below their boxes that never go away.

Why:
- The roster numbers are drawn in a tall font whose glyphs extend below the short box.
- Each refresh only erases that box, so pixels drawn past it are never cleared.
- The text shim drew glyphs with no clipping, so anything outside the box stayed on screen.

How:
- Add a rectangular clip to the graphics port, honored by the text paths, defaulting to wide open.
- Add ClipRect and a GetClipRect readback so callers can set and restore the clip.
- Clip each roster number to the box it is erased into, then restore the prior clip.
- Compatible with macOS and Windows since it only touches the shared shim and game code.
```

### Reference the human contribution guidance

The human-facing project guidance lives in `README.md` (the "Reporting Bugs" and the two
"Building" sections). Align PRs and issues with it; do not duplicate it here, and do not add any
agent or AI oriented text to `README.md` or other tracked files.
