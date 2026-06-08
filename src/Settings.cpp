#include "Settings.hpp"

#include <SDL3/SDL_filesystem.h>

#include <algorithm>
#include <cmath>
#include <string>

#include <phosg/Filesystem.hh>
#include <phosg/JSON.hh>
#include <phosg/Strings.hh>

#include "Types.hpp"

static phosg::PrefixedLogger settings_log("[Settings] ", DEFAULT_LOG_LEVEL);

// Keep the window between original size and 4x so a stray value can't produce a
// window larger than any reasonable display.
static constexpr float MIN_SCALE = 1.0f;
static constexpr float MAX_SCALE = 4.0f;

RealmzSettings load_realmz_settings() {
  RealmzSettings settings;

  const char* base_path = SDL_GetBasePath();
  if (!base_path) {
    settings_log.warning_f("Could not get base path: {}; using default window settings", SDL_GetError());
    return settings;
  }
  std::string path = std::string(base_path) + "settings.json";

  std::string data;
  try {
    data = phosg::load_file(path);
  } catch (const std::exception& e) {
    // No settings file is the normal case, so this is not a warning.
    settings_log.info_f("Could not read {} ({}); using default window settings", path, e.what());
    return settings;
  }

  try {
    auto root = phosg::JSON::parse(data);
    phosg::JSON empty_dict = phosg::JSON::dict();
    const phosg::JSON& scaling = root.get("scaling", empty_dict);

    double scale = scaling.get_float("scale", 1.0);
    settings.scale = std::clamp(static_cast<float>(scale), MIN_SCALE, MAX_SCALE);

    std::string filter = scaling.get_string("filter", "auto");
    if (filter == "nearest") {
      settings.scale_mode = SDL_SCALEMODE_NEAREST;
    } else if (filter == "linear") {
      settings.scale_mode = SDL_SCALEMODE_LINEAR;
    } else {
      if (filter != "auto") {
        settings_log.warning_f("Unknown filter '{}'; using auto", filter);
      }
      // auto: nearest for whole-number scales keeps the pixel art crisp;
      // fractional scales use linear to avoid unevenly sized pixels.
      bool is_integer_scale = (settings.scale == std::floor(settings.scale));
      settings.scale_mode = is_integer_scale ? SDL_SCALEMODE_NEAREST : SDL_SCALEMODE_LINEAR;
    }
  } catch (const std::exception& e) {
    settings_log.warning_f("Could not parse {} ({}); using default window settings", path, e.what());
    return RealmzSettings{};
  }

  settings_log.info_f("Window scale {}x, filter {}", settings.scale,
      (settings.scale_mode == SDL_SCALEMODE_NEAREST) ? "nearest" : "linear");
  return settings;
}
