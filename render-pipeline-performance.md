# Render pipeline performance review

Scope: the SDL3 compatibility shim that re-implements the Mac Toolbox drawing
path (`src/QuickDraw.cpp`, `src/WindowManager.cpp`, `src/EventManager.cpp`,
`src/Font.cpp`) plus the phosg `Image` primitives it composites with. The goal
is to find things that cause slow frames, rendering-driven slowness, and input
lag, and to rank each by impact and fix difficulty. Everything below is an
incremental change; none of it requires rewriting the layer.

> Branch note: this document lives on a branch based on `main`. Some line
> numbers in the findings were first captured on the `integration` branch, where
> the `recomposite()` body sits about 200 lines later (present at
> `WindowManager.cpp:1389`) because of extra merged features. On `main` and
> `fix-treasure-screen` the present is at `WindowManager.cpp:1186-1195`. Two
> items exist only on `integration`: the gamma pass (finding #5) and the
> per-present `SDL_SetTextureScaleMode`, both added with the port menu. Refer to
> the named functions; they are stable across branches. A later section
> cross-checks everything against the maintainer Discord discussion and the
> in-tree mitigations on `fix-treasure-screen` (those mitigations are not on
> `main`, so they are not in this branch's code).

## How the pipeline actually works (so the findings make sense)

Rendering is reactive, not a fixed frame loop. There is no continuous render
thread. A frame is produced whenever game code calls a QuickDraw primitive
(`DrawString`, `LineTo`, `CopyBits`, `PlotCIcon`, `DrawPicture`, etc.). Each of
those primitives draws into a per-window CPU buffer (`CCGrafPort::data`, a phosg
`ImageRGBA8888N`) and then calls `WindowManager::recomposite_from_window(...)`
(`src/QuickDraw.cpp:852,863,926,941,948,956,971,1069,1076,1083`).

`WindowManager::recomposite()` (`src/WindowManager.cpp:1291`) is the single
choke point. For each call it:

1. Optionally clears the 800x600 `screen_port` and CPU-composites the affected
   window plus every window above it, pixel by pixel, with alpha blending
   (`src/WindowManager.cpp:1296-1333`).
2. Optionally runs full-frame gamma correction (`:1349-1372`).
3. Creates a brand new `SDL_Surface` from the pixels, creates a brand new
   `SDL_Texture` from that surface, clears the renderer, draws the texture, and
   presents (`:1373-1389`).
4. Calls `SDL_SyncWindow` (`:1390`).

Because a naive implementation would run that entire chain after every single
primitive, the original game code has been instrumented with an escape hatch:
`WindowManager_SetEnableRecomposite(0)` batches many draws and recomposites once
at the end (`src/WindowManager.h:144-151`, used across `swap.c`, `booty.c`,
`combatupdate-2.c`, `updatechar*.c`, etc.). That batching is the main reason the
game is usable today. The findings below are mostly about making the single
recomposite that batching funnels into much cheaper, which is where the
remaining cost concentrates, especially during animations.

Animations are the worst case: spell and treasure animations call
`WindowManager_RecompositeAlways()` once per animation frame inside their draw
loop (`src/realmz_orig/cast.c:293`, `src/realmz_orig/booty.c:1625`), so every
animation frame pays the full chain above.

## Findings, ranked

| # | Issue | Impact | Difficulty |
|---|-------|--------|------------|
| 0 | Distributed Windows builds are Debug (`-O0` plus per-primitive stderr logging) | High (measured) | Trivial |
| 1 | New GPU texture allocated and full frame re-uploaded every recomposite | High -> Low (measured) | Low |
| 2 | `SDL_SyncWindow` after every present | Med-High | Low |
| 3 | Whole-screen CPU recomposite with no dirty-rect / no opaque fast path | High | Med-High |
| 9 | Present welded to every recomposite (no coalescing across draws) | High | Medium |
| 4 | `load_font` uses C++ exceptions as normal cache-miss control flow | Medium | Low |
| 5 | Gamma path rebuilds the LUT and reallocates a full-frame buffer every present (integration only) | Medium (opt-in) | Low |
| 6 | Text drawing re-rasterizes font size and double-copies every call, no glyph/string cache | Medium | Medium |
| 7 | Eager `std::format` allocations in debug-log arguments on hot paths | Low-Med | Low |
| 8 | Per-pixel bounds-checked blit primitives (no row memcpy) | Med | Med |

Findings #1, #2, #3, and #9 are the present/compositing hot path the maintainer
discussion is circling; they are detailed below along with a cross-check against
that discussion and a branch experiment plan. #9 was added after reviewing the
discussion. Finding #0 was added after measuring, and is now the headline.

---

## Measurements (Release vs Debug, instrumented present path)

The `recomposite()` present path was instrumented (commit on
`render-perf-investigation`, opt-in via `REALMZ_PERF=1`) and the same play
sequence was captured on Windows in a Debug build and a Release build, plus the
two experiment toggles. Numbers below are mean milliseconds per present over
about 5000 presents per run. Each present time is the sum of its phases.

Debug vs Release, baseline (the headline, finding #0):

| phase | Debug mean | Release mean | speedup |
|-------|-----------:|-------------:|--------:|
| composite | 6.71 | 0.50 | ~13x |
| upload (texture) | 0.62 | 0.62 | ~1x |
| present | 0.36 | 0.41 | ~1x |
| sync | 0.001 | 0.001 | - |
| total | 7.71 | 1.53 | ~5x |

The composite phase is pure CPU per-pixel work, so `-O0` was inflating it about
13x; in Release it is half a millisecond. The phase breakdown isolates the gain:
only the composite phase (entirely `phosg::Image` work) sped up, while the SDL
upload and present phases were unchanged from Debug to Release. The compositor
author independently confirmed the mechanism, that `phosg::Image`, used for all
the rendering, has many hot per-pixel loops that depend on compiler
optimizations being enabled. The user also confirmed by feel that the Release
build "feels normal" where the Debug build felt slow. Since
`build-windows.sh` defaults `BUILD_TYPE=Debug` and `rebuild-integration.sh` does
not override it, the shared test releases people judge as slow are Debug builds
(the shipped exe is ~41 MB, matching a Debug build; Release is ~28 MB). Building
and distributing Release (or RelWithDebInfo) is the single highest-impact change
here and is effectively one line.

Experiment results in Release (mean ms/present; scene-controlled rows fix the
window count so composite is comparable):

| run | composite | upload | present | sync | total |
|-----|----------:|-------:|--------:|-----:|------:|
| baseline | 0.50 | 0.62 | 0.41 | 0.001 | 1.53 |
| A (no SyncWindow) | 0.50 | 0.67 | 0.47 | 0.001 | 1.64 |
| B (persistent texture) | 0.49 | 0.25 | 0.55 | 0.001 | 1.30 |
| A+B | 0.52 | 0.26 | 0.58 | 0.001 | 1.36 |
| baseline, 1 window | 0.38 | 0.61 | 0.37 | 0.001 | 1.36 |
| B, 1 window | 0.37 | 0.25 | 0.51 | 0.001 | 1.13 |
| baseline, 4 windows | 1.31 | 0.65 | 0.58 | 0.001 | 2.53 |
| B, 4 windows | 1.23 | 0.24 | 0.58 | 0.001 | 2.11 |

Conclusions:

- Experiment A (drop `SDL_SyncWindow`): no measurable effect. `sync` is about
  0.001 ms and `present` is about 0.4 ms (a vsync-locked present would be ~16
  ms). This confirms empirically that there is no vsync stall, the maintainers'
  "vsync locked present" belief is wrong on this setup. Do not pursue A as an
  optimization; remove the call only for tidiness if at all.
- Experiment B (persistent streaming texture): a consistent win. `upload` drops
  from ~0.62 to ~0.25 ms and total present-path time falls about 15 to 17
  percent across both light (1 window) and heavy (4 window) scenes. Some cost
  shifts into `present` (streaming uploads flush at draw/present time), but the
  net is clearly positive. Promote B to the default path and delete the
  per-present surface/texture recreation. This is finding #1, now measured: the
  fix is real but the absolute saving is sub-millisecond because the Debug build
  was the real cost.
- In Release the present path is not a bottleneck at all: mean ~1.5 ms, p99 ~4.3
  ms, essentially 0 percent of presents over the 16.7 ms (60fps) budget. The
  "composite dominates" picture from the first capture was a Debug artifact.

Caveat on scope: this instrumentation times only `recomposite()` (composite plus
present). It does not time the drawing primitives that run between recomposites
(CopyBits, text, oval/line draws), nor game logic. If any animation still feels
slow in a Release build, the next measurement should cover the draw side
(findings #4, #6, #7, #8) and the number of presents per animation (finding #9),
not the present path itself.

---

## Cross-check against the maintainer Discord discussion and the fix-treasure-screen branch

Source: `discord-discussion-render-performance.txt` (contributors Josh, Kanhef,
fuzziqersoftware) plus the in-tree mitigations on the `fix-treasure-screen`
branch (`src/realmz_orig/booty.c`). Each claim was checked against the code
rather than taken at face value.

### fuzziqersoftware (designed the compositor): accurate, and sets the ground rule

He describes the compositor as a deliberately small QuickDraw-like op set drawn
on the CPU, with SDL used only to present, chosen because mapping each QD
primitive onto a hardware-accelerated SDL primitive would be faster but hard to
keep pixel-accurate. That matches the code exactly: CPU compositing in phosg
`Image`, a single `SDL_RenderTexture`/`SDL_RenderPresent` at the end of
`recomposite()`. His constraint, keep compositing behavior as accurate as today,
is the right ground rule, and every item in this document preserves output
pixels. Findings #1, #2, the new #9 below, and the opaque fast path in #3 are
exactly the "make the existing system faster without changing its behavior" work
he says he is open to.

### Josh (animations are slow, slower than SheepShaver): right symptom, wrong mechanism

The animation loops he points at do not sleep or yield. There is no `Delay` or
`SystemTask` in the spell loop (`cast.c`, around the `WindowManager_RecompositeAlways`
call) or the loot loop (`booty.c`, the `for (t = 0; animate && t < 24; t++)`
flourish). So the slowness is not the loops failing to cede time, which is the
cooperative-multitasking framing. Each iteration draws and then forces a full
`recomposite()`: full-screen CPU composite, a freshly created GPU texture,
present, and `SDL_SyncWindow`. That per-frame cost is the bottleneck (findings
#1, #2, #3). The "slower than SheepShaver" observation fits: an emulator blits
one framebuffer per refresh and never recreates a GPU texture per primitive. So
Josh has the right area; the mechanism is the expensive present path, not
timeslice behavior.

The branch already carries two hand-applied mitigations that corroborate this:
the loot loop presents only every third frame (`booty.c`, `if ((t % 3) == 0)`)
and skips the flourish entirely when another click is queued (`MouseDownPending`,
a port-only EventManager extension). Both are workarounds for an expensive
present, not fixes to it.

### The "vsync locked present" belief is not supported by the code

Two comments attribute the per-present stall to vsync (`booty.c` near the
item-keep highlight, and the flourish comment "instead of one vsync locked
present per oval"). There is no vsync anywhere: `SDL_CreateRenderer` is called
with default properties, and nothing sets `SDL_SetRenderVSync`, the vsync
create-property, or any render hint (confirmed by grep across `src/` and the
CMake files). In SDL3 that means present vsync is off. So whatever blocking the
maintainers felt is not SDL vsync. The likely real contributors are (a)
per-present GPU texture creation and upload (finding #1), (b) `SDL_SyncWindow`
after each present (finding #2), and possibly (c) the desktop compositor pacing a
windowed present to the display refresh, which is environment dependent and not
something the `t % 3` throttle addresses at the source. This should be measured
directly (timestamps around `SDL_CreateTextureFromSurface`, `SDL_RenderPresent`,
and `SDL_SyncWindow`) before committing to a fix. If a compositor turns out to be
pacing presents, the durable answer is to present less often (finding #9), not to
throttle by hand inside each animation.

### Kanhef (residual pixels may be an original bug): true case-by-case, but the loot sparkle is port-introduced

The loot sparkle's leftover pixels are handled in-tree by repainting the affected
cells (`booty.c`, the "Repaint the emptied cell and its neighbours" block), and
the comment blames antialiasing: "FrameOval is antialiased ... they leave stray
coloured pixels." The implementation does not support that explanation.
`FrameOval` calls `CCGrafPort::draw_oval`, which uses a non-antialiased midpoint
algorithm, and its XOR mode writes `phosg::invert(read(x, y))`, where `invert` is
`(255 - R, 255 - G, 255 - B, A)`, a clean involution. Drawing the same oval twice
with XOR therefore cancels exactly; antialiasing is not involved. The artifact is
real, but the more likely mechanism is that the growing XOR oval and the
shrinking srcCopy oval overlap as they converge, so the srcCopy pass corrupts
pixels that the second XOR pass then cannot restore. For Kanhef's claim: residual
pixels are case-by-case. The Items-screen and treasure cases he recalls from
retail Realmz may well be original, but this loot sparkle is a port-side
consequence of how XOR erase is implemented, so "it is just the original bug"
does not generalize here. This is a correctness note, not a performance one, but
it matters for finding #3 (any compositor change must reproduce these results)
and it has a small performance angle: the repaint workaround adds extra blit
work that a saved-background restore or a non-overlapping erase could avoid.

---

## 9. Present is performed synchronously inside every recomposite

Location: `WindowManager::recomposite()` (`src/WindowManager.cpp`, present at
`:1194` on `fix-treasure-screen`, `:1389` on `integration`). New finding,
surfaced by the discussion above.

Every composite immediately presents. There is no separation between "update the
screen buffer" and "show it on the GPU." The manual
`WindowManager_SetEnableRecomposite` batching exists precisely to collapse many
draws into one present, and the `booty.c` `t % 3` throttle is a second, ad hoc
version of the same idea. Both are symptoms of present being welded to draw.

Decouple them: have `recomposite()` composite into `screen_port` and set a
`needs_present` flag, then perform the actual `SDL_RenderTexture` /
`SDL_RenderPresent` once per event-loop turn (for example in
`enqueue_pending_events` / `get_next_event`, which already runs between game
actions). Multiple recomposites between two event pumps then cost one present
instead of N. This generalizes the existing batching so individual call sites no
longer manage it, and it caps present rate to the event cadence regardless of
whether a compositor paces to vblank. It pairs naturally with the persistent
streaming texture (#1): composite-to-buffer stays on the CPU and accurate;
present becomes a single cheap upload-and-show.

Caveat to verify: animations that rely on seeing intermediate frames (the
spell/loot flourishes) must still present per intended frame. The mapping is
straightforward (`RecompositeAlways` becomes force-present-now), but it needs
testing so animations do not collapse to only their final frame.

Impact: High. Difficulty: Medium.

---

## 1. New GPU texture allocated and full frame re-uploaded every recomposite

Location: `src/WindowManager.cpp:1373-1389`.

```cpp
auto surface = sdl_make_unique(SDL_CreateSurfaceFrom(w, h, SDL_PIXELFORMAT_RGBA8888, ...));
auto texture = sdl_make_unique(SDL_CreateTextureFromSurface(renderer, surface.get()));
...
SDL_RenderTexture(renderer, texture.get(), nullptr, nullptr);
SDL_RenderPresent(renderer);
```

Every recomposite builds a throwaway surface, creates a throwaway GPU texture
from it (an 800x600x4 = ~1.9 MB GPU allocation plus upload), draws it once, and
frees both at end of scope. `SDL_CreateTextureFromSurface` produces a
`SDL_TEXTUREACCESS_STATIC` texture, which is the wrong access pattern for a
buffer that changes every frame. During animations (finding #3's worst case),
this allocate-upload-free cycle runs once per animation frame.

Why it costs: per-frame GPU texture creation and destruction is the single most
expensive avoidable thing in the present path. It also fragments GPU memory and
defeats the driver's ability to pipeline uploads.

Fix (no rewrite): create one persistent streaming texture at renderer-creation
time (`src/WindowManager.cpp:1110-1116`) sized 800x600 with
`SDL_TEXTUREACCESS_STREAMING`, store it on the `WindowManager`, and in
`recomposite()` push pixels with `SDL_UpdateTexture` (or `SDL_LockTexture` and
write directly). Set the scale mode once on the persistent texture and re-apply
only when it changes. This removes a GPU alloc/free and a surface alloc/free per
frame and is a localized change to one function plus one member.

Impact: High. Difficulty: Low.

---

## 2. `SDL_SyncWindow` after every present

Location: `src/WindowManager.cpp:1390`.

`SDL_SyncWindow` blocks until pending window-system state changes (size, move,
fullscreen transitions) have been applied by the compositor/OS. Calling it after
every present serializes the render loop against the window server on every
frame, which adds latency and can stall, particularly on macOS and under
Wayland/X11. There is no resize in progress on a normal draw, so the call has
nothing useful to do most of the time.

Fix: remove the per-present `SDL_SyncWindow`, or only call it from the resize
handlers that actually change window size (`snap_aspect`/`set_window_size`,
`src/WindowManager.cpp:1435-1460`) where syncing is meaningful. Verify
fullscreen enter/exit still behaves (that path is already special-cased per the
comment at `:1108`).

Impact: Medium-High (latency, not throughput). Difficulty: Low.

---

## 3. Whole-screen CPU recomposite, no dirty rectangles, no opaque fast path

Location: `src/WindowManager.cpp:1296-1333` and the phosg blit it calls.

When a single window updates, `recomposite()` composites that window and every
window stacked above it; when `recomposite_all()` is used (the common case after
batching, and on every resize/expose, `src/EventManager.cpp:438,442`) it clears
the entire 800x600 buffer and composites every window bottom-to-top. There is no
notion of a dirty rectangle: a one-line text change in a status area still
recomposites and re-uploads the full screen.

The compositing itself goes through `copy_from_with_blend`, whose inner loop is
per-pixel with two bounds checks and an index multiply per pixel
(`.deps-src/phosg/src/Image.hh:1397-1408`, accessor at
`:1248-1250`). The blend lambda special-cases fully transparent and fully opaque
pixels (`:1589-1600`), but it still visits every pixel one at a time. For a
fully opaque window (the common case: the main game window covers the screen)
this could be whole-row `memcpy`s instead.

Why it costs: this is the CPU half of every frame. For full-screen composites
that is 480,000 pixel iterations, repeated for each stacked window, on every
update. It is the dominant cost during animations alongside finding #1.

Fixes (incremental, pick any subset):
- Opaque fast path: in `recomposite()`, when a window's source row is fully
  opaque, copy the row with `memcpy` into `screen_port.data` instead of going
  through the per-pixel blend. The shim owns this loop; phosg need not change.
- Dirty rectangles: have the recomposite entry points accept the changed rect
  (the drawing primitives already know it) and composite plus
  `SDL_UpdateTexture` only that sub-rect. This is the larger change and where
  the "Med-High" difficulty comes from, but it compounds with finding #1 since
  `SDL_UpdateTexture` supports partial updates.
- Skip the clear in `recomposite_all` when the bottom window is opaque and
  covers the whole screen (it overwrites the cleared pixels anyway,
  `:1298`).

Impact: High. Difficulty: Medium-High (opaque fast path alone is Low-Medium and
gets most of the win).

---

## 4. `load_font` uses exceptions as normal cache-miss control flow

Location: `src/Font.cpp:41-58`.

```cpp
Font load_font(int16_t font_id) {
  try { return tt_fonts_by_id.at(font_id); } catch (const std::out_of_range&) {}
  try { return bm_renderers_by_id.at(font_id); } catch (const std::out_of_range&) { ... }
}
```

`load_font` is called on the hot path of every `draw_text`, `draw_text` (no
rect), and `measure_text` (`src/QuickDraw.cpp:211,245,299`). For any font that is
not a TrueType font, the first `.at()` throws and catches a `std::out_of_range`
every single call, and for an uncached bitmap font the second `.at()` throws too.
Throwing and catching a C++ exception is orders of magnitude slower than a map
lookup, and it happens once or twice per text draw on text-heavy screens
(character sheets, combat log, shop lists).

Fix: replace `.at()` + catch with `find()`:

```cpp
if (auto it = tt_fonts_by_id.find(font_id); it != tt_fonts_by_id.end()) return it->second;
if (auto it = bm_renderers_by_id.find(font_id); it != bm_renderers_by_id.end()) return it->second;
// load + insert bitmap font here
```

Impact: Medium. Difficulty: Low.

---

## 5. Gamma path rebuilds the LUT and reallocates a full-frame buffer every present

Location: `src/WindowManager.cpp:1349-1372`.

When color correction is enabled (default is "Off", `src/PortMenu.hpp:46-51`, so
this only bites users who turn it on), each present recomputes a 256-entry LUT
with `std::pow` and `std::round`, allocates a fresh `std::vector<uint32_t>` of
480,000 entries, and transforms the whole frame on the CPU before upload.

Fixes:
- Cache the LUT as a member, recompute only when `gamma_idx` changes (it changes
  from a menu, not per frame).
- Reuse a persistent scratch buffer instead of allocating a vector each present.
- Better still, fold the gamma map into the `SDL_UpdateTexture`/lock copy from
  finding #1 so it is a single pass with no extra buffer.

Impact: Medium, but only when the feature is enabled. Difficulty: Low.

---

## 6. Text drawing re-rasterizes font size and double-copies every call

Location: `src/QuickDraw.cpp:177-313`, helpers at `:161-175,235-240`.

Per `draw_text` call the code:
- calls `TTF_SetFontSize(tt_font, this->txSize)` (`:218,249`) and
  `set_font_style` (`:219,250`), which invalidate and rebuild the font's glyph
  cache when size/style differ from the previous call;
- renders the whole string to a new SDL surface with
  `TTF_RenderText_Blended_Wrapped` (`:181`);
- copies that surface pixel by pixel into a fresh phosg image in
  `image_for_sdl_surface` (`:167-174`);
- then `copy_from_with_blend`s that image onto the port (`:193`).

`measure_text` and the no-rect `draw_text` additionally build and destroy a
`TTF_Text` object just to measure (`pixel_dimensions_for_text`, `:235-240`),
and `measure_text` is frequently called right before drawing the same string.
Nothing is cached, so repeated identical strings (labels, repeated stat lines)
re-render from scratch every frame they appear.

Fixes (incremental):
- Track the last size/style set on each cached font and skip
  `TTF_SetFontSize`/`set_font_style` when unchanged.
- Cache rendered glyph runs or whole-string textures keyed by (font, size,
  style, color, text) for the small set of repeated strings, or at least reuse
  the measurement between the `measure_text` and `draw_text` of the same string.
- Avoid the extra `image_for_sdl_surface` copy by blitting the SDL text surface
  toward the destination more directly where the format allows.

Impact: Medium. Difficulty: Medium.

---

## 7. Eager `std::format` allocations in debug-log arguments on hot paths

Location: `CCGrafPort::ref()` at `src/QuickDraw.hpp:80-82`, used as a logging
argument in hot primitives, e.g. `CopyBits` at `src/QuickDraw.cpp:969`.

```cpp
inline std::string ref() const { return std::format("P-{:016X}", ...); }
...
dst_port->log.debug_f("CopyBits({}, {}, ...)", src_port->ref(), dst_port->ref(), ...);
```

The phosg logger correctly skips formatting when the level is disabled
(`.deps-src/phosg/src/Strings.hh:206-215`), but the *arguments* are evaluated by
the caller before the level check. So `ref()` heap-allocates two `std::string`s
on every `CopyBits` even when debug logging is off, and similar patterns appear
in other per-primitive log calls. `CopyBits` is the map/tile blit path, so this
is a steady stream of allocations during map drawing.

Fix: pass the raw pointer (`static_cast<const void*>(port)`) and let the `{}`
format it lazily, or guard the expensive log calls with `if (log.should_log(...))`,
or drop `ref()` from the hottest primitives. Cheap and safe.

Impact: Low-Medium. Difficulty: Low.

---

## 8. Per-pixel bounds-checked blit primitives (no row memcpy)

Location: phosg `copy_from`/`copy_from_with_*` and `write_rect`
(`.deps-src/phosg/src/Image.hh:1304-1314,1394-1408`).

`CopyBits` srcCopy with matching sizes routes to the `ResizeMode::NONE` loop,
which is still per-pixel `check`/`read`/`write`. `write_rect` (used by
`erase_rect`/`fill_rect`, `src/QuickDraw.cpp:107-119`) fills solid rectangles one
pixel at a time. These are correct but leave easy speed on the table: same-format
same-size copies and solid fills are exactly what `memcpy`/`memset`-per-row are
for.

phosg is a pinned external dependency, so the clean place to act is the shim: for
the common cases (`srcCopy` with equal rects and matching RGBA8888 format; solid
opaque `write_rect`) do the row copy/fill in `CCGrafPort` before delegating to
the generic phosg path. This overlaps with the opaque fast path in finding #3.

Impact: Medium. Difficulty: Medium (must keep behavior identical; touch the shim,
not the pinned dep).

---

## What is already handled well (do not "fix" these)

- The recomposite batching escape hatch (`WindowManager_SetEnableRecomposite`)
  is the right mechanism and is already applied to the expensive multi-draw
  routines. The work here is making each batched recomposite cheaper, not adding
  more batching.
- The logger short-circuits formatting when the level is disabled, so log
  strings themselves are not built on hot paths (only their arguments are, see
  finding #7).
- Key-repeat de-duplication in the event queue (`src/EventManager.cpp:461-482`)
  already prevents input backlog from making the game feel sluggish; leave it.
- Rendering is reactive, so there is no idle CPU spin; `SystemTask` sleeps in the
  game's busy loops (`src/EventManager.cpp:551-558`). No frame cap is needed.

## Suggested order of work (revised after measuring)

1. Finding #0: build and distribute Release (or RelWithDebInfo), not Debug. This
   is the measured headline, about 5x on the present path and "feels normal" by
   hand, and it is effectively a one-line default change in `build-windows.sh`.
   Everything below is secondary to this.
2. Finding #1 via Experiment B: make the persistent streaming texture the default
   and delete the per-present surface/texture recreation. Measured ~15 to 17
   percent off the present path, low risk, pixel-identical.
3. Finding #9 (present coalescing) if further present-path wins are wanted; it
   removes the need for hand-applied throttles like `booty.c`'s `t % 3`. Lower
   urgency now that each Release present is ~1.5 ms.
4. Do NOT pursue Finding #2 / Experiment A (drop `SDL_SyncWindow`): measured zero
   benefit, sync is already ~0.001 ms.
5. If animation still feels slow in Release, measure the draw side first, then
   act on Finding #4 (font cache exception) and #7 (log arg allocations), which
   are trivial and safe, before the larger Finding #3 (opaque fast path, then
   dirty rectangles) and Finding #6 (text caching) / #8 (row blits).
6. Finding #5 (gamma LUT cache) only matters on `integration`, and only if color
   correction is enabled.

## Branch experiment plan (executed; results recorded)

Prototyped on `render-perf-investigation` (based on `main`). The instrumentation
is opt-in via `REALMZ_PERF`, so the default build is unaffected.

1. Measure first. Done. Per-present phase timing in `recomposite()`. Captured
   Debug first (misleading), then Release.
2. Experiment A (`REALMZ_NO_SYNCWINDOW=1`): done, no measurable effect. Not
   adopted; the toggle remains for re-testing.
3. Experiment B (persistent streaming texture): done and **adopted as the
   default present path**; the per-present surface/texture recreation and the
   `REALMZ_PERSISTENT_TEXTURE` toggle are removed.
4. Build default: the local `build-windows.sh` now defaults `BUILD_TYPE=Release`
   (finding #0). This file is developer-local; the upstream equivalent is to make
   distributed Windows builds Release.
5. Draw-side instrumentation: added (`qd_perf`). Leaf QuickDraw primitives time
   themselves; each per-present line now also reports `gap` (wall time since the
   previous present), `draw` (accumulated primitive time), and `draws` (count).
   This is the harness for the next capture round: profile the specific scenes
   that still feel slow in Release (loot flourish, begin-adventure redraw) and
   see whether the cost is in drawing, compositing, or outside the render path.
6. Experiment C (present coalescing, #9): not yet prototyped. Optional follow-up,
   informed by what the draw-side capture shows.

Validation still pending: confirm output stays pixel-identical with the texture
change. `ENABLE_RECOMPOSITE_DEBUG` dumps the composited buffer to BMP, so a
before/after diff of the same scene is a cheap regression check.

Methodology notes worth keeping: measure in Release, not Debug (Debug inflates
the CPU composite about 13x and adds per-primitive stderr logging that slows the
whole game), and make sure the timing flag is actually set in every run (the
first attempt left `REALMZ_PERF` unset for three of four runs because each batch
file is a separate process).
