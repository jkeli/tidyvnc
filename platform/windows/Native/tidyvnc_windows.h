/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_WINDOWS_H
#define TIDYVNC_WINDOWS_H
/* The WinUI frontend's native helper, tidyvnc_windows.dll (plans/native-ui-winui
 * DECISIONS.md D1): the Direct3D 11 presenter, keyboard translation and hooks,
 * cursor creation and display topology. Called only by TidyVNC.Native, never
 * by the core. Conventions follow tidyvnc.h: fixed-width values, opaque
 * pointers, int32_t HRESULT-style results (0 = S_OK, negative = failure) and
 * no C++ types or exceptions across the boundary. */
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#if defined(TIDYVNC_WINDOWS_BUILDING)
#define TVW_API __declspec(dllexport)
#else
#define TVW_API __declspec(dllimport)
#endif

typedef struct { int32_t x, y, width, height; } tvw_rect;

/* ---- Presenter (DESKTOP.md section 1, D11) -----------------------------------------
 * One presenter per desktop view. Create/attach/destroy on the UI thread;
 * resize/clear/upload/present on the view's render thread (the device is
 * multithread-protected, so attach may overlap rendering). The swap chain is a
 * flip-model composition swap chain, BGRA8, two buffers. Uploaded pixels go to
 * a persistent texture the size of the swap chain; present copies it into the
 * back buffer and presents the dirty rectangles. A result of
 * DXGI_ERROR_DEVICE_REMOVED/RESET (0x887A0005/0x887A0007) means: destroy,
 * create again, reattach and upload the whole frame. */
typedef struct tvw_presenter tvw_presenter;
TVW_API int32_t tvw_presenter_create(tvw_presenter** out);
/* panel is the IUnknown of a Microsoft.UI.Xaml.Controls.SwapChainPanel; the
 * helper queries ISwapChainPanelNative and calls SetSwapChain. Null detaches. */
TVW_API int32_t tvw_presenter_attach(tvw_presenter*, void* panel);
/* Physical pixels (1..16384). scale_x/scale_y are the panel's composition
 * scale; the inverse is applied so one swap-chain pixel is one screen pixel. */
TVW_API int32_t tvw_presenter_resize(tvw_presenter*, uint32_t width, uint32_t height, float scale_x, float scale_y);
/* Fills a rectangle of the persistent texture with opaque black (letterbox). */
TVW_API int32_t tvw_presenter_clear(tvw_presenter*, const tvw_rect* area);
/* Copies tightly packed or strided BGRA pixels to (x, y), clipped to the texture. */
TVW_API int32_t tvw_presenter_upload(tvw_presenter*, const uint8_t* bgra, uint32_t stride, const tvw_rect* area);
/* Presents; zero dirty rectangles present the whole surface. */
TVW_API int32_t tvw_presenter_present(tvw_presenter*, const tvw_rect* dirty, uint32_t count);
/* Reads back a rectangle of the persistent texture (tests and diagnostics;
 * stalls the pipeline). The rectangle must lie within the swap chain. */
TVW_API int32_t tvw_presenter_read(tvw_presenter*, const tvw_rect* area, uint8_t* bgra, uint32_t stride);
TVW_API void tvw_presenter_destroy(tvw_presenter*);

/* ---- Keyboard translation (DESKTOP.md section 5, D12) -------------------------------
 * The retained vncviewer/KeyboardWin32 logic without FLTK: scan codes become
 * RFB/QEMU key codes (extended keys set 0x80), keysyms come from ToUnicode
 * with the current layout, AltGr (left Ctrl then right Alt within 50 ms) is
 * merged into ISO_Level3_Shift, VK_PACKET text becomes keysyms including
 * surrogate pairs, and the Shift-release and IME release workarounds apply.
 * The 100 ms AltGr decision timer is explicit: when the result reports a
 * deadline, the host calls tvw_keyboard_timeout at or after it. One
 * translator per desktop view; UI thread only. */
typedef struct tvw_keyboard tvw_keyboard;
enum { TVW_KEY_PRESS = 1, TVW_KEY_RELEASE = 2 };
typedef struct {
  uint32_t kind;            /* TVW_KEY_PRESS or TVW_KEY_RELEASE */
  int32_t system_key_code;  /* Scan code with the extended bit as 0x80, or 0x1ff for VK_PACKET */
  uint32_t key_code;        /* RFB/QEMU key code (0 for VK_PACKET) */
  uint32_t keysym;          /* Press only; 0 when no symbol */
} tvw_key_event;
typedef struct {
  uint32_t message;  /* WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP or a mouse message */
  uint64_t wparam;
  int64_t lparam;
  uint32_t time;     /* MSG.time, milliseconds */
} tvw_key_message;
typedef struct {
  uint32_t consumed;       /* The message belongs to the keyboard path (swallow it). */
  uint32_t count;          /* Events written. */
  uint32_t timer_pending;  /* An AltGr decision is armed. */
  uint32_t timer_delay_ms; /* Fire tvw_keyboard_timeout after this delay. */
} tvw_key_result;
TVW_API int32_t tvw_keyboard_create(tvw_keyboard** out);
/* Up to capacity events (8 suffice for any single message). */
TVW_API int32_t tvw_keyboard_handle(tvw_keyboard*, const tvw_key_message*, tvw_key_event* events, uint32_t capacity,
                                    tvw_key_result* result);
/* The AltGr timer fired: a held left Ctrl is sent after all. */
TVW_API int32_t tvw_keyboard_timeout(tvw_keyboard*, tvw_key_event* events, uint32_t capacity, tvw_key_result* result);
TVW_API void tvw_keyboard_reset(tvw_keyboard*);
TVW_API void tvw_keyboard_destroy(tvw_keyboard*);
/* Ordered keysym candidates of a physical key for shortcut matching. */
TVW_API int32_t tvw_keyboard_keysyms(tvw_keyboard*, int32_t system_key_code, uint32_t* keysyms, uint32_t capacity, uint32_t* count);
/* RFB LED bits (1 = Scroll, 2 = Num, 4 = Caps) of the local keyboard, and synchronization to a remote state. */
TVW_API uint32_t tvw_keyboard_led_state(void);
TVW_API int32_t tvw_keyboard_set_led_state(uint32_t state);

/* ---- UI-thread keyboard message hook (D12) -----------------------------------------
 * A WH_GETMESSAGE hook on the calling (UI) thread. While enabled, keyboard
 * messages (WM_KEY*, WM_SYSKEY*, WM_CHAR, WM_SYSCHAR, WM_DEADCHAR,
 * WM_SYSDEADCHAR) retrieved on this thread go to the callback before XAML sees
 * them; a nonzero return replaces the message with WM_NULL. Mouse messages
 * are passed to the callback too (they cancel AltGr detection) but never
 * swallowed. Character messages generated by TranslateMessage for swallowed
 * keys never arrive. */
typedef uint32_t (*tvw_hook_callback)(void* context, const tvw_key_message* message);
typedef struct tvw_hook tvw_hook;
TVW_API int32_t tvw_hook_install(tvw_hook_callback callback, void* context, tvw_hook** out);
TVW_API void tvw_hook_enable(tvw_hook*, uint32_t enabled);
TVW_API void tvw_hook_remove(tvw_hook*);

/* ---- Low-level keyboard capture (SERVICES.md section 8) ----------------------------
 * WH_KEYBOARD_LL on a dedicated thread while capture is active, as
 * vncviewer/win32.c does: every key, including system combinations (Alt+Tab,
 * the Windows key, Alt+Esc, Ctrl+Esc), is suppressed system-wide and reposted
 * to the target window as WM_KEYDOWN/WM_KEYUP (or WM_SYSKEY*). Caps, Num and
 * Scroll Lock pass through, keys already down when capture starts pass their
 * release, and nothing is intercepted while the target is not foreground.
 * Ctrl+Alt+Del, Win+L and input for elevated windows cannot be captured.
 * Start and stop on the target window's UI thread, which must have the message
 * hook installed: it repairs the thread keyboard state that interception
 * leaves stale and maps left/right modifier keys to the generic ones. */
typedef struct tvw_capture tvw_capture;
TVW_API int32_t tvw_capture_start(uint64_t target_hwnd, tvw_capture** out);
TVW_API void tvw_capture_stop(tvw_capture*);

/* ---- Cursor (DESKTOP.md section 3, D13) ------------------------------------------
 * Straight-alpha RGBA (the core cursor sampler's format) to an HCURSOR with the
 * hotspot. Destroy with tvw_cursor_destroy. max_width/max_height report the
 * largest size Windows accepts for a cursor on this system. */
TVW_API int32_t tvw_cursor_create(const uint8_t* rgba, uint32_t width, uint32_t height, uint32_t hotspot_x, uint32_t hotspot_y,
                                  uint64_t* cursor);
TVW_API void tvw_cursor_destroy(uint64_t cursor);
TVW_API void tvw_cursor_limits(uint32_t* max_width, uint32_t* max_height);

/* ---- Displays (SERVICES.md section 7) ----------------------------------------------
 * Active monitors from QueryDisplayConfig joined with GetMonitorInfo and
 * GetDpiForMonitor. id is an opaque SHA-256 prefix of the monitor device path
 * (stable across reboots and enumeration order); mirrored targets are one
 * display with mirrored set. Rectangles are physical pixels in virtual-screen
 * coordinates; scale is DPI / 96. */
typedef struct {
  uint64_t id;
  int32_t x, y, width, height;             /* Monitor bounds, physical pixels */
  int32_t work_x, work_y, work_width, work_height;
  uint32_t dpi_x, dpi_y, primary, mirrored;
  uint64_t monitor;                        /* HMONITOR, valid until the next topology change */
  uint16_t name[64];                       /* Friendly name (UTF-16, NUL terminated), or empty */
} tvw_display;
TVW_API int32_t tvw_displays(tvw_display* displays, uint32_t capacity, uint32_t* count);

#ifdef __cplusplus
}
#endif
#endif
