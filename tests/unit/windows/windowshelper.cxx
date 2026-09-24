// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
//
// tidyvnc_windows.dll C API (plans/native-ui-winui TODO W3.4): the presenter
// without a panel (upload, clear, read back, present, resize), the keyboard
// surface with layout-independent keys, the UI-thread message hook, capture
// preconditions, cursors and display topology. Nothing here changes system
// state: LED synchronisation is covered by keyboardtranslator.cxx instead.

#include <windows.h>
#include <unknwn.h>

#include <set>
#include <vector>

#include <gtest/gtest.h>

#include "tidyvnc_windows.h"

namespace {

struct Presenter {
  tvw_presenter* value = nullptr;
  Presenter() { EXPECT_EQ(S_OK, tvw_presenter_create(&value)); }
  ~Presenter() { tvw_presenter_destroy(value); }
};

std::vector<uint8_t> solid(int width, int height, uint8_t b, uint8_t g, uint8_t r)
{
  std::vector<uint8_t> pixels((size_t)width * height * 4);
  for (size_t i = 0; i < pixels.size(); i += 4) {
    pixels[i] = b;
    pixels[i + 1] = g;
    pixels[i + 2] = r;
    pixels[i + 3] = 255;
  }
  return pixels;
}

// An IUnknown that is not a SwapChainPanel.
class PlainObject final : public IUnknown {
public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
  {
    if (iid == __uuidof(IUnknown)) {
      *out = this;
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
};

uint32_t pixel(tvw_presenter* presenter, int x, int y)
{
  uint8_t bgra[4] = {};
  tvw_rect area = {x, y, 1, 1};
  EXPECT_EQ(S_OK, tvw_presenter_read(presenter, &area, bgra, 4));
  return (uint32_t)bgra[0] | (uint32_t)bgra[1] << 8 | (uint32_t)bgra[2] << 16 | (uint32_t)bgra[3] << 24;
}

} // namespace

TEST(WindowsHelper, PresenterUploadsClearsReadsBackAndPresents)
{
  Presenter p;
  ASSERT_NE(nullptr, p.value);
  ASSERT_EQ(S_OK, tvw_presenter_resize(p.value, 640, 480, 1.5f, 1.5f));
  EXPECT_EQ(0xff000000u, pixel(p.value, 0, 0)); // A new surface is opaque black.

  auto red = solid(256, 256, 0, 0, 255);
  tvw_rect tile = {256, 0, 256, 256};
  ASSERT_EQ(S_OK, tvw_presenter_upload(p.value, red.data(), 256 * 4, &tile));
  EXPECT_EQ(0xffff0000u, pixel(p.value, 256, 0));
  EXPECT_EQ(0xffff0000u, pixel(p.value, 511, 255));
  EXPECT_EQ(0xff000000u, pixel(p.value, 255, 0));

  // Clipped at the right and bottom edges, with a source stride.
  auto green = solid(300, 300, 0, 255, 0);
  tvw_rect corner = {512, 400, 200, 100};
  ASSERT_EQ(S_OK, tvw_presenter_upload(p.value, green.data(), 300 * 4, &corner));
  EXPECT_EQ(0xff00ff00u, pixel(p.value, 639, 479));
  // Entirely outside, and negative origins, are clipped away.
  tvw_rect outside = {700, 0, 10, 10};
  EXPECT_EQ(S_OK, tvw_presenter_upload(p.value, green.data(), 300 * 4, &outside));
  tvw_rect negative = {-10, -10, 20, 20};
  ASSERT_EQ(S_OK, tvw_presenter_upload(p.value, green.data(), 300 * 4, &negative));
  EXPECT_EQ(0xff00ff00u, pixel(p.value, 9, 9));
  EXPECT_EQ(0xff000000u, pixel(p.value, 10, 10));

  tvw_rect letterbox = {256, 0, 128, 128};
  ASSERT_EQ(S_OK, tvw_presenter_clear(p.value, &letterbox));
  EXPECT_EQ(0xff000000u, pixel(p.value, 300, 100));
  EXPECT_EQ(0xffff0000u, pixel(p.value, 400, 200));

  EXPECT_EQ(S_OK, tvw_presenter_present(p.value, nullptr, 0));
  tvw_rect dirty[2] = {{256, 0, 256, 256}, {0, 0, 10, 10}};
  EXPECT_EQ(S_OK, tvw_presenter_present(p.value, dirty, 2));
  tvw_rect invisible = {1000, 1000, 5, 5};
  EXPECT_EQ(S_OK, tvw_presenter_present(p.value, &invisible, 1));
  std::vector<tvw_rect> many(100, tvw_rect{0, 0, 1, 1});
  EXPECT_EQ(S_OK, tvw_presenter_present(p.value, many.data(), (uint32_t)many.size()));

  // Same size keeps content (only the scale changes); a new size starts black.
  ASSERT_EQ(S_OK, tvw_presenter_resize(p.value, 640, 480, 1.0f, 1.0f));
  EXPECT_EQ(0xffff0000u, pixel(p.value, 400, 200));
  ASSERT_EQ(S_OK, tvw_presenter_resize(p.value, 1920, 1080, 2.0f, 2.0f));
  EXPECT_EQ(0xff000000u, pixel(p.value, 400, 200));
  EXPECT_EQ(S_OK, tvw_presenter_present(p.value, nullptr, 0));
}

TEST(WindowsHelper, PresenterRejectsInvalidArguments)
{
  Presenter p;
  EXPECT_EQ(E_POINTER, tvw_presenter_create(nullptr));
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_resize(p.value, 0, 10, 1, 1));
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_resize(p.value, 16385, 10, 1, 1));
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_resize(p.value, 10, 10, 0, 1));
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_resize(p.value, 10, 10, 1, -1));
  ASSERT_EQ(S_OK, tvw_presenter_resize(p.value, 10, 10, 1, 1));
  uint8_t pixels[16] = {};
  tvw_rect area = {0, 0, 2, 2};
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_upload(p.value, pixels, 4, &area)); // Stride below width*4.
  EXPECT_EQ(E_POINTER, tvw_presenter_upload(p.value, nullptr, 8, &area));
  tvw_rect beyond = {9, 9, 2, 2};
  EXPECT_EQ(E_INVALIDARG, tvw_presenter_read(p.value, &beyond, pixels, 8));
  EXPECT_EQ(E_POINTER, tvw_presenter_present(p.value, nullptr, 1));
  PlainObject notAPanel;
  EXPECT_EQ(E_NOINTERFACE, tvw_presenter_attach(p.value, static_cast<IUnknown*>(&notAPanel)));
  EXPECT_EQ(S_OK, tvw_presenter_attach(p.value, nullptr));
  tvw_presenter_destroy(nullptr);
}

TEST(WindowsHelper, KeyboardTranslatesLayoutIndependentKeys)
{
  tvw_keyboard* keyboard = nullptr;
  ASSERT_EQ(S_OK, tvw_keyboard_create(&keyboard));
  tvw_key_event events[8];
  tvw_key_result result;

  tvw_key_message escape = {WM_KEYDOWN, VK_ESCAPE, 1 | (0x01 << 16), 100};
  ASSERT_EQ(S_OK, tvw_keyboard_handle(keyboard, &escape, events, 8, &result));
  EXPECT_EQ(1u, result.consumed);
  ASSERT_EQ(1u, result.count);
  EXPECT_EQ((uint32_t)TVW_KEY_PRESS, events[0].kind);
  EXPECT_EQ(0x01, events[0].system_key_code);
  EXPECT_EQ(0x01u, events[0].key_code);
  EXPECT_EQ(0xff1bu, events[0].keysym);

  // Pause becomes the RFB Pause key code; F1 has no layout dependence.
  tvw_key_message pause = {WM_KEYDOWN, VK_PAUSE, 1 | (0x45 << 16), 110};
  ASSERT_EQ(S_OK, tvw_keyboard_handle(keyboard, &pause, events, 8, &result));
  ASSERT_EQ(1u, result.count);
  EXPECT_EQ(0xc6u, events[0].key_code);
  EXPECT_EQ(0xff13u, events[0].keysym);

  tvw_key_message release = {WM_KEYUP, VK_ESCAPE, 1 | (0x01 << 16) | (3LL << 30), 120};
  ASSERT_EQ(S_OK, tvw_keyboard_handle(keyboard, &release, events, 8, &result));
  ASSERT_EQ(1u, result.count);
  EXPECT_EQ((uint32_t)TVW_KEY_RELEASE, events[0].kind);

  // Too little room is reported, never overrun.
  ASSERT_EQ(E_NOT_SUFFICIENT_BUFFER, tvw_keyboard_handle(keyboard, &escape, events, 0, &result));
  EXPECT_EQ(0u, result.count);

  // Mouse messages are not consumed; unrelated messages are ignored.
  tvw_key_message mouse = {WM_MOUSEMOVE, 0, 0, 130};
  ASSERT_EQ(S_OK, tvw_keyboard_handle(keyboard, &mouse, events, 8, &result));
  EXPECT_EQ(0u, result.consumed);
  EXPECT_EQ(0u, result.timer_pending);

  // No pending AltGr decision: a timeout sends nothing.
  ASSERT_EQ(S_OK, tvw_keyboard_timeout(keyboard, events, 8, &result));
  EXPECT_EQ(0u, result.count);

  uint32_t keysyms[64];
  uint32_t count = 0;
  ASSERT_EQ(S_OK, tvw_keyboard_keysyms(keyboard, 0x01, keysyms, 64, &count));
  ASSERT_GE(count, 1u);
  EXPECT_EQ(0xff1bu, keysyms[0]);
  EXPECT_EQ(E_NOT_SUFFICIENT_BUFFER, tvw_keyboard_keysyms(keyboard, 0x01, keysyms, 0, &count));

  uint32_t leds = tvw_keyboard_led_state();
  EXPECT_EQ(0u, leds & ~7u);

  tvw_keyboard_reset(keyboard);
  tvw_keyboard_destroy(keyboard);
  EXPECT_EQ(E_POINTER, tvw_keyboard_handle(nullptr, &escape, events, 8, &result));
}

namespace {

struct HookRecord {
  std::vector<UINT> seen;
  uint32_t swallow = 1;
};

uint32_t record(void* context, const tvw_key_message* message)
{
  auto* hook = static_cast<HookRecord*>(context);
  hook->seen.push_back(message->message);
  return hook->swallow;
}

HWND messageWindow()
{
  return CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
}

UINT pump(HWND window, UINT message)
{
  PostMessageW(window, message, VK_ESCAPE, 1 | (0x01 << 16));
  MSG msg;
  EXPECT_TRUE(GetMessageW(&msg, window, 0, 0));
  return msg.message;
}

} // namespace

TEST(WindowsHelper, MessageHookSwallowsKeysOnlyWhileEnabled)
{
  HWND window = messageWindow();
  ASSERT_NE(nullptr, window);
  HookRecord record_;
  tvw_hook* hook = nullptr;
  ASSERT_EQ(S_OK, tvw_hook_install(record, &record_, &hook));
  tvw_hook* second = nullptr;
  EXPECT_EQ(HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS), tvw_hook_install(record, &record_, &second));

  EXPECT_EQ((UINT)WM_KEYDOWN, pump(window, WM_KEYDOWN)); // Disabled: untouched and unseen.
  EXPECT_TRUE(record_.seen.empty());

  tvw_hook_enable(hook, 1);
  EXPECT_EQ((UINT)WM_NULL, pump(window, WM_KEYDOWN));
  EXPECT_EQ((UINT)WM_NULL, pump(window, WM_SYSKEYUP));
  EXPECT_EQ((UINT)WM_NULL, pump(window, WM_CHAR));
  EXPECT_EQ((UINT)WM_LBUTTONDOWN, pump(window, WM_LBUTTONDOWN)); // Seen, never swallowed.
  record_.swallow = 0;
  EXPECT_EQ((UINT)WM_KEYUP, pump(window, WM_KEYUP));
  EXPECT_EQ((UINT)WM_APP, pump(window, WM_APP)); // Not keyboard or mouse: not seen.
  EXPECT_EQ((std::vector<UINT>{WM_KEYDOWN, WM_SYSKEYUP, WM_CHAR, WM_LBUTTONDOWN, WM_KEYUP}), record_.seen);

  // Capture needs a window on this thread; it never intercepts for a
  // window that is not in the foreground (a message-only window never is).
  tvw_capture* capture = nullptr;
  EXPECT_EQ(E_INVALIDARG, tvw_capture_start(0, &capture));
  ASSERT_EQ(S_OK, tvw_capture_start((uint64_t)(uintptr_t)window, &capture));
  tvw_capture* another = nullptr;
  EXPECT_EQ(HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS), tvw_capture_start((uint64_t)(uintptr_t)window, &another));
  tvw_capture_stop(capture);

  tvw_hook_remove(hook);
  EXPECT_EQ(E_NOT_VALID_STATE, tvw_capture_start((uint64_t)(uintptr_t)window, &capture));
  DestroyWindow(window);
}

TEST(WindowsHelper, CursorsFromStraightAlphaRgba)
{
  std::vector<uint8_t> rgba(32 * 32 * 4, 0);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    rgba[i] = 255;
    rgba[i + 3] = (uint8_t)(i % 256);
  }
  uint64_t cursor = 0;
  ASSERT_EQ(S_OK, tvw_cursor_create(rgba.data(), 32, 32, 3, 4, &cursor));
  ASSERT_NE(0u, cursor);
  ICONINFO info = {};
  ASSERT_TRUE(GetIconInfo(reinterpret_cast<HICON>((uintptr_t)cursor), &info));
  EXPECT_FALSE(info.fIcon);
  EXPECT_EQ(3u, info.xHotspot);
  EXPECT_EQ(4u, info.yHotspot);
  DeleteObject(info.hbmColor);
  DeleteObject(info.hbmMask);
  tvw_cursor_destroy(cursor);
  EXPECT_EQ(E_INVALIDARG, tvw_cursor_create(rgba.data(), 32, 32, 32, 0, &cursor));
  EXPECT_EQ(E_INVALIDARG, tvw_cursor_create(rgba.data(), 0, 32, 0, 0, &cursor));
  uint32_t width = 0, height = 0;
  tvw_cursor_limits(&width, &height);
  EXPECT_GE(width, 32u);
  EXPECT_GE(height, 32u);
}

TEST(WindowsHelper, DisplaysHaveStableIdsAndOnePrimary)
{
  uint32_t count = 0;
  HRESULT probe = tvw_displays(nullptr, 0, &count);
  if (count == 0)
    GTEST_SKIP() << "No active display paths in this session";
  EXPECT_EQ(E_NOT_SUFFICIENT_BUFFER, probe);
  std::vector<tvw_display> displays(count);
  ASSERT_EQ(S_OK, tvw_displays(displays.data(), count, &count));
  std::set<uint64_t> ids;
  int primaries = 0;
  for (const tvw_display& display : displays) {
    EXPECT_NE(0u, display.id);
    ids.insert(display.id);
    EXPECT_GT(display.width, 0);
    EXPECT_GT(display.height, 0);
    EXPECT_GE(display.dpi_x, 96u);
    EXPECT_NE(0u, display.monitor);
    EXPECT_LE(display.work_width, display.width);
    primaries += display.primary ? 1 : 0;
    if (display.primary) {
      EXPECT_EQ(0, display.x);
      EXPECT_EQ(0, display.y);
    }
  }
  EXPECT_EQ(displays.size(), ids.size());
  EXPECT_EQ(1, primaries);

  // Enumeration order and repeated queries give the same identities.
  std::vector<tvw_display> again(count);
  ASSERT_EQ(S_OK, tvw_displays(again.data(), count, &count));
  for (size_t i = 0; i < displays.size(); i++)
    EXPECT_EQ(displays[i].id, again[i].id);
}
