/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <stdint.h>
uint32_t native_macos_qnum(uint16_t hardware);
uint32_t native_macos_special_keysym(uint16_t hardware);
uint32_t native_unicode_keysym(uint32_t scalar);
uint32_t native_macos_modifier_down(uint16_t hardware, uint64_t flags);
/* Main-thread layout query; returns up to capacity unique ordered keysyms. */
uint32_t native_macos_shortcut_candidates(uint16_t hardware, uint32_t* symbols, uint32_t capacity);
/* Main-thread create/active/destroy. Create never requests system permission.
 * Callback has no owner context, so invalidation cannot retain a host object. */
void* native_macos_keyboard_capture_create(void);
uint32_t native_macos_keyboard_capture_active(void* capture);
void native_macos_keyboard_capture_destroy(void* capture);
