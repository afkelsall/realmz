#pragma once

#include <SDL3/SDL_surface.h>

// Settings loaded from settings.json in the directory containing the
// executable. The game always renders into a fixed 800x600 logical buffer;
// these control how that buffer is presented to the screen so the window can
// be larger than 800x600 on modern displays.
struct RealmzSettings {
  // Window size multiplier applied to the 800x600 logical size. 1.0 keeps the
  // original size. Clamped to a sane range when loaded.
  float scale = 1.0f;
  // Texture filter used when the logical buffer is scaled up to the window.
  SDL_ScaleMode scale_mode = SDL_SCALEMODE_NEAREST;
};

// Loads settings.json from the directory containing the executable. Any problem
// (missing file, parse failure, out-of-range values) falls back to defaults.
RealmzSettings load_realmz_settings();
