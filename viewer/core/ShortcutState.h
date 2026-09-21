/* Copyright 2021-2025 Pierre Ossman for Cendio AB
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this software; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307,
 * USA.
 */

#ifndef TIDYVNC_SHORTCUT_STATE_H
#define TIDYVNC_SHORTCUT_STATE_H
#include <array>
#include <cstddef>
#include <cstdint>
namespace viewer {
// Executor-confined shared shortcut classifier. No callbacks or timers.
// Fixed storage bounds arbitrary physical key IDs; a full press or invalid
// modifier mask throws before mutation. Hosts release wire keys on shortcut /
// unarm, and reset on focus loss, routing changes and disconnect.
class ShortcutState {
public:
  ShortcutState();
  enum KeyAction { KeyNormal, KeyUnarm, KeyShortcut, KeyIgnore };
  enum Modifier { Control = 1, Shift = 2, Alt = 4, Super = 8 };
  static constexpr size_t capacity = 1024;
  void setModifiers(unsigned mask);
  KeyAction handleKeyPress(int keyCode, uint32_t keySym);
  KeyAction handleKeyRelease(int keyCode);
  void reset();
private:
  static unsigned keySymToModifier(uint32_t keySym);
  unsigned modifierMask;
  enum State { Idle, Arming, Armed, Rearming, Firing, Wedged };
  State state;
  struct Key { int code; uint32_t symbol; bool fired; };
  std::array<Key, capacity> keys{};
  size_t count = 0;
};
}
#endif
