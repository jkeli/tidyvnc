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

#include "ShortcutState.h"
#include <stdexcept>
#define XK_MISCELLANY
#include <rfb/keysymdef.h>

namespace viewer {
ShortcutState::ShortcutState() :
  modifierMask(0), state(Idle)
{
}

void ShortcutState::setModifiers(unsigned mask)
{
  if (mask & ~15u) throw std::invalid_argument("Invalid shortcut modifier mask");
  modifierMask = mask;
  reset();
}

ShortcutState::KeyAction ShortcutState::handleKeyPress(int keyCode,
                                                           uint32_t keySym)
{
  unsigned modifier, pressedMask;

  size_t index = 0;
  while (index < count && keys[index].code != keyCode) ++index;
  if (index == count) {
    if (count == capacity) throw std::length_error("Shortcut key capacity exceeded");
    keys[count++] = {keyCode, keySym, false};
  } else keys[index].symbol = keySym;

  if (modifierMask == 0)
    return KeyNormal;

  modifier = keySymToModifier(keySym);

  pressedMask = 0;
  for (size_t i = 0; i < count; ++i)
    pressedMask |= keySymToModifier(keys[i].symbol);

  switch (state) {
  case Idle:
  case Arming:
  case Rearming:
    if (pressedMask == modifierMask) {
      // All triggering modifier keys are pressed
      state = Armed;
    } if (modifier && ((modifier & modifierMask) == modifier)) {
      // The new key is part of the triggering set
      if (state == Idle)
        state = Arming;
    } else {
      // The new key was something else
      state = Wedged;
    }
    return KeyNormal;
  case Armed:
    if (modifier && ((modifier & modifierMask) == modifier)) {
      // The new key is part of the triggering set
      return KeyNormal;
    } else if (modifier) {
      // The new key is some other modifier
      state = Wedged;
      return KeyNormal;
    } else {
      // The new key was something else
      state = Firing;
      keys[index].fired = true;
      return KeyShortcut;
    }
    break;
  case Firing:
    if (modifier) {
      // The new key is a modifier (may or may not be part of the
      // triggering set)
      return KeyIgnore;
    } else {
      // The new key was something else
      keys[index].fired = true;
      return KeyShortcut;
    }
  default:
    break;
  }

  return KeyNormal;
}

ShortcutState::KeyAction ShortcutState::handleKeyRelease(int keyCode)
{
  bool firedKey;
  unsigned pressedMask;
  KeyAction action;

  size_t index = 0;
  while (index < count && keys[index].code != keyCode) ++index;
  firedKey = index < count && keys[index].fired;
  if (index < count) {
    keys[index] = keys[--count]; keys[count] = {};
  }

  pressedMask = 0;
  for (size_t i = 0; i < count; ++i)
    pressedMask |= keySymToModifier(keys[i].symbol);

  switch (state) {
  case Arming:
    action = KeyNormal;
    break;
  case Armed:
    if (count == 0)
      action = KeyUnarm;
    else if (pressedMask == modifierMask)
      action = KeyNormal;
    else {
      action = KeyNormal;
      state = Rearming;
    }
    break;
  case Rearming:
    if (count == 0)
      action = KeyUnarm;
    else
      action = KeyNormal;
    break;
  case Firing:
    if (firedKey)
      action = KeyShortcut;
    else
      action = KeyIgnore;
    break;
  default:
    action = KeyNormal;
  }

  if (count == 0)
    state = Idle;

  return action;
}

void ShortcutState::reset()
{
  state = Idle;
  count = 0; keys = {};
}

unsigned ShortcutState::keySymToModifier(uint32_t keySym)
{
  switch (keySym) {
  case XK_Control_L:
  case XK_Control_R:
    return Control;
  case XK_Shift_L:
  case XK_Shift_R:
    return Shift;
  case XK_Alt_L:
  case XK_Alt_R:
    return Alt;
  case XK_Super_L:
  case XK_Super_R:
  case XK_Hyper_L:
  case XK_Hyper_R:
    return Super;
  }

  return 0;
}

}
