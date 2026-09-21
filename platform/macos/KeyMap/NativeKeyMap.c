/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "NativeKeyMap.h"
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#define XK_LATIN1
#define XK_MISCELLANY
#include <rfb/keysymdef.h>
#include <rfb/XF86keysym.h>
#include "../../../vncviewer/keysym2ucs.h"
#define kVK_Menu 0x6E /* Same compatibility definition as KeyboardMacOS.mm. */
#include "SpecialKeys.inc"
extern const unsigned short code_map_osx_to_qnum[];
extern const unsigned int code_map_osx_to_qnum_len;
uint32_t native_macos_qnum(uint16_t hardware) {
  return hardware < code_map_osx_to_qnum_len ? code_map_osx_to_qnum[hardware] : 0;
}
uint32_t native_macos_special_keysym(uint16_t hardware) {
  for (unsigned i = 0; i < sizeof(kvk_map)/sizeof(kvk_map[0]); ++i)
    if (kvk_map[i][0] == hardware) return kvk_map[i][1];
  return 0;
}
uint32_t native_unicode_keysym(uint32_t scalar) { return ucs2keysym(scalar); }
uint32_t native_macos_modifier_down(uint16_t hardware, uint64_t flags) {
  uint64_t mask = 0;
  switch (hardware) {
  case kVK_Shift: mask = NX_DEVICELSHIFTKEYMASK; break;
  case kVK_RightShift: mask = NX_DEVICERSHIFTKEYMASK; break;
  case kVK_Control: mask = NX_DEVICELCTLKEYMASK; break;
  case kVK_RightControl: mask = NX_DEVICERCTLKEYMASK; break;
  case kVK_Option: mask = NX_DEVICELALTKEYMASK; break;
  case kVK_RightOption: mask = NX_DEVICERALTKEYMASK; break;
  case kVK_Command: mask = NX_DEVICELCMDKEYMASK; break;
  case kVK_RightCommand: mask = NX_DEVICERCMDKEYMASK; break;
  default: break;
  }
  return (flags & mask) != 0;
}

/* Layout candidate ordering follows KeyboardMacOS::translateToKeySyms, with
 * an owned input-source reference and bounded output. Queries are only needed
 * for an armed local shortcut, not for ordinary text/IME input. */
uint32_t native_macos_shortcut_candidates(uint16_t hardware, uint32_t* symbols, uint32_t capacity) {
  if (!symbols || !capacity) return 0;
  uint32_t special = native_macos_special_keysym(hardware);
  if (special) { symbols[0] = special; return 1; }
  TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
  if (!source) return 0;
  CFDataRef data = TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData);
  const UCKeyboardLayout* layout = data ? (const UCKeyboardLayout*)CFDataGetBytePtr(data) : NULL;
  uint32_t count = 0;
  if (layout) {
    const unsigned singles[] = {0,cmdKey,shiftKey,alphaLock,optionKey,controlKey};
    for (unsigned pass = 0; pass < 37 && count < capacity; ++pass) {
      unsigned modifiers = pass < 6 ? singles[pass] : (pass-5)*cmdKey;
      UInt32 dead = 0; UniChar text[4]; UniCharCount length = 0;
      OSStatus result = UCKeyTranslate(layout,hardware,kUCKeyActionDown,(modifiers>>8)&0xff,
        LMGetKbdType(),0,&dead,4,&length,text);
      if (result != noErr) continue;
      uint32_t scalar = 0;
      if (dead) {
        result = UCKeyTranslate(layout,hardware,kUCKeyActionDown,(modifiers>>8)&0xff,
          LMGetKbdType(),0,&dead,4,&length,text);
        if (result != noErr || length != 1) continue;
        scalar = ucs2combining(text[0]);
        if (scalar == (uint32_t)-1) continue;
      } else if (length == 1) scalar = text[0];
      else if (length == 2 && text[0] >= 0xd800 && text[0] <= 0xdbff && text[1] >= 0xdc00 && text[1] <= 0xdfff)
        scalar = 0x10000 + ((text[0]-0xd800)<<10) + text[1]-0xdc00;
      else continue;
      uint32_t symbol = ucs2keysym(scalar), i = 0;
      if (!symbol) continue;
      while (i < count && symbols[i] != symbol) ++i;
      if (i == count) symbols[count++] = symbol;
    }
  }
  CFRelease(source); return count;
}
