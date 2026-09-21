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

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <core/i18n.h>
#include "ShortcutHandler.h"

// Keep list of valid values in sync with shortcutModifiers
unsigned ShortcutHandler::parseModifier(const char* key)
{
  if (strcasecmp(key, "Ctrl") == 0)
    return Control;
  else if (strcasecmp(key, "Shift") == 0)
    return Shift;
  else if (strcasecmp(key, "Alt") == 0)
    return Alt;
  else if (strcasecmp(key, "Win") == 0)
    return Super;
  else if (strcasecmp(key, "Super") == 0)
    return Super;
  else if (strcasecmp(key, "Option") == 0)
    return Alt;
  else if (strcasecmp(key, "Cmd") == 0)
    return Super;
  else
    return 0;
}

const char* ShortcutHandler::modifierString(unsigned key)
{
  if (key == Control)
    return "Ctrl";
  if (key == Shift)
    return "Shift";
  if (key == Alt)
    return "Alt";
  if (key == Super)
    return "Super";

  return "";
}

const char* ShortcutHandler::modifierPrefix(unsigned mask,
                                            bool justPrefix)
{
  static char prefix[256];

  prefix[0] = '\0';
  if (mask & Control) {
#ifdef __APPLE__
    strcat(prefix, "⌃");
#else
    strcat(prefix, _("Ctrl"));
    strcat(prefix, "+");
#endif
  }
  if (mask & Shift) {
#ifdef __APPLE__
    strcat(prefix, "⇧");
#else
    strcat(prefix, _("Shift"));
    strcat(prefix, "+");
#endif
  }
  if (mask & Alt) {
#ifdef __APPLE__
    strcat(prefix, "⌥");
#else
    strcat(prefix, _("Alt"));
    strcat(prefix, "+");
#endif
  }
  if (mask & Super) {
#ifdef __APPLE__
    strcat(prefix, "⌘");
#else
    strcat(prefix, _("Win"));
    strcat(prefix, "+");
#endif
  }

  if (prefix[0] == '\0')
    return "";

  if (justPrefix) {
#ifndef __APPLE__
    prefix[strlen(prefix)-1] = '\0';
#endif
    return prefix;
  }

#ifdef __APPLE__
  strcat(prefix, "\xc2\xa0"); // U+00A0 NO-BREAK SPACE
#endif

  return prefix;
}
