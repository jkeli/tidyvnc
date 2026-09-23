/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "NativeKeyMap.h"
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct { CFMachPortRef tap; CFRunLoopSourceRef source; } NativeCapture;
static CGEventRef redirect(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* context) {
  (void)proxy; (void)context;
  if (type != kCGEventKeyDown && type != kCGEventKeyUp && type != kCGEventFlagsChanged) return event;
  /* Same repeat workaround as the retained cocoa adapter. Events posted to the
   * process bypass the session tap; no event or host reference is retained. */
  CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,0);
  CGEventPostToPid(getpid(),event);
  return NULL;
}
uint32_t native_macos_keyboard_capture_trusted(void) { return AXIsProcessTrusted() ? 1 : 0; }
void* native_macos_keyboard_capture_create(void) {
  if (!AXIsProcessTrusted()) return NULL;
  NativeCapture* capture = calloc(1,sizeof(*capture));
  if (!capture) return NULL;
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
  capture->tap = CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,redirect,NULL);
  if (!capture->tap) { free(capture); return NULL; }
  capture->source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,capture->tap,0);
  if (!capture->source) { CFMachPortInvalidate(capture->tap); CFRelease(capture->tap); free(capture); return NULL; }
  CFRunLoopAddSource(CFRunLoopGetMain(),capture->source,kCFRunLoopCommonModes);
  return capture;
}
uint32_t native_macos_keyboard_capture_active(void* value) {
  NativeCapture* capture = value;
  return capture && CFMachPortIsValid(capture->tap) && CGEventTapIsEnabled(capture->tap);
}
void native_macos_keyboard_capture_destroy(void* value) {
  NativeCapture* capture = value;
  if (!capture) return;
  CGEventTapEnable(capture->tap,false);
  CFRunLoopRemoveSource(CFRunLoopGetMain(),capture->source,kCFRunLoopCommonModes);
  CFMachPortInvalidate(capture->tap);
  CFRelease(capture->source); CFRelease(capture->tap); free(capture);
}
