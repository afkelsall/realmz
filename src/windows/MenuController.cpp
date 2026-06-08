#include <algorithm>

#include "./WinMenuController.hpp"
#include "MenuController.h"
#include "WindowManager.hpp"

WinMenu::Item win_menu_item_from_menu_item(const Menu::Item& item) {
  return WinMenu::Item{
      .name = item.name,
      .icon_id = item.icon_id,
      .key_equivalent = item.key_equivalent,
      .mark_character = item.mark_character,
      .style_flags = item.style_flags,
      .enabled = item.enabled,
      .checked = item.checked};
}

std::shared_ptr<WinMenu> win_menu_from_menu(std::shared_ptr<Menu> menu) {
  std::vector<WinMenu::Item> items;
  std::transform(
      menu->items.begin(),
      menu->items.end(),
      std::back_inserter(items),
      win_menu_item_from_menu_item);
  return std::make_shared<WinMenu>(
      menu->menu_id,
      menu->proc_id,
      menu->title,
      menu->enabled,
      std::move(items));
}

void MCSync(std::shared_ptr<MenuList> menuList, void (*callback)(int16_t, int16_t)) {
  auto sdl_window = WindowManager::instance().get_sdl_window();

  auto win_menu_list = std::make_shared<WinMenuList>();

  std::transform(
      menuList->menus.begin(),
      menuList->menus.end(),
      std::back_inserter(win_menu_list->menus),
      win_menu_from_menu);

  // Hierarchical menus (e.g. the Volume and Speed submenus) live in submenus and are
  // referenced from a parent item via the 0x1B/mark_character marker. They must be carried
  // across so WinMenuSync can attach them; otherwise those menus appear inert.
  std::transform(
      menuList->submenus.begin(),
      menuList->submenus.end(),
      std::back_inserter(win_menu_list->submenus),
      win_menu_from_menu);

  WinMenuSync(sdl_window.get(), win_menu_list, callback);
}

void MCCreatePopupMenu(
    void* nsWindow, // unused
    std::shared_ptr<Menu> menu,
    std::pair<int16_t, int16_t> loc,
    void (*callback)(int16_t, int16_t)) {
  auto sdl_window = WindowManager::instance().get_sdl_window();
  auto m = win_menu_from_menu(menu);
  auto result = WinCreatePopupMenu(sdl_window.get(), m);
  callback(m->menu_id, result);
}
