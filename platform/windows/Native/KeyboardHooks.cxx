// Copyright 2002-2005 RealVNC Ltd; 2026 TidyVNC contributors.
// Licensed under GPL-2.0-or-later.
//
// The UI-thread WH_GETMESSAGE hook (D12) and the low-level keyboard capture
// (SERVICES.md section 8). Capture follows vncviewer/win32.c: every key except
// the lock keys is intercepted system-wide and reposted to the target window,
// and the UI-thread hook repairs the thread keyboard state Windows stops
// updating while keys are intercepted.

#include "tidyvnc_windows.h"

#include <windows.h>

#include <atomic>
#include <new>

struct tvw_hook {
  HHOOK hook = nullptr;
  DWORD thread = 0;
  tvw_hook_callback callback = nullptr;
  void* context = nullptr;
  bool enabled = false;
};

struct tvw_capture {
  HWND target = nullptr;
  DWORD uiThread = 0;
  HANDLE thread = nullptr;
  DWORD threadId = 0;
  HANDLE ready = nullptr;
  HRESULT status = S_OK;
  // Keys pressed when capture started must be allowed to return to their
  // neutral state; touched only on the capture thread after start.
  BYTE state[256] = {};
};

namespace {

// One hook per UI thread; WH_GETMESSAGE procedures carry no context.
thread_local tvw_hook* currentHook = nullptr;

// Only one capture at a time (as in win32.c). Written by start/stop on the UI
// thread, read by the capture thread's hook procedure.
std::atomic<tvw_capture*> activeCapture{nullptr};

bool isKeyMessage(UINT message)
{
  return message == WM_KEYDOWN || message == WM_SYSKEYDOWN || message == WM_KEYUP || message == WM_SYSKEYUP;
}

bool isKeyboardMessage(UINT message)
{
  switch (message) {
  case WM_CHAR:
  case WM_SYSCHAR:
  case WM_DEADCHAR:
  case WM_SYSDEADCHAR:
    return true;
  default:
    return isKeyMessage(message);
  }
}

// win32.c message_hook: the low-level intercept stops Windows updating our
// thread's keyboard state, so do it by hand, and translate the left/right
// virtual keys to the generic ones the translator expects.
void repairInterceptedKey(MSG* msg)
{
  BYTE state[256];
  GetKeyboardState(state);

  bool down = !(msg->lParam & (1u << 31));
  if (down)
    state[msg->wParam & 0xff] |= 0x80;
  else
    state[msg->wParam & 0xff] &= ~0x80;

  auto combine = [&state](int left, int right, int generic) {
    if ((state[left] & 0x80) || (state[right] & 0x80))
      state[generic] |= 0x80;
    else
      state[generic] &= ~0x80;
  };
  combine(VK_LSHIFT, VK_RSHIFT, VK_SHIFT);
  combine(VK_LCONTROL, VK_RCONTROL, VK_CONTROL);
  combine(VK_LMENU, VK_RMENU, VK_MENU);

  SetKeyboardState(state);

  switch (msg->wParam) {
  case VK_LSHIFT:
  case VK_RSHIFT:
    msg->wParam = VK_SHIFT;
    // The extended bit is also always missing for right shift
    msg->lParam &= ~(1 << 24);
    break;
  case VK_LCONTROL:
  case VK_RCONTROL:
    msg->wParam = VK_CONTROL;
    break;
  case VK_LMENU:
  case VK_RMENU:
    msg->wParam = VK_MENU;
    break;
  }
}

LRESULT CALLBACK getMessageProc(int code, WPARAM wParam, LPARAM lParam)
{
  tvw_hook* hook = currentHook;
  if (code == HC_ACTION && wParam == PM_REMOVE) {
    MSG* msg = reinterpret_cast<MSG*>(lParam);
    tvw_capture* capture = activeCapture.load();
    if (capture && capture->uiThread == GetCurrentThreadId() && isKeyMessage(msg->message))
      repairInterceptedKey(msg);
    if (hook && hook->enabled) {
      bool keyboard = isKeyboardMessage(msg->message);
      if (keyboard || (msg->message >= WM_MOUSEFIRST && msg->message <= WM_MOUSELAST)) {
        tvw_key_message message{msg->message, (uint64_t)msg->wParam, (int64_t)msg->lParam, msg->time, 0,
                                (uint64_t)(uintptr_t)msg->hwnd};
        uint32_t swallow = hook->callback(hook->context, &message);
        if (keyboard && swallow) {
          msg->message = WM_NULL;
          msg->wParam = 0;
          msg->lParam = 0;
        }
      }
    }
  }
  return CallNextHookEx(nullptr, code, wParam, lParam);
}

LRESULT CALLBACK lowLevelProc(int code, WPARAM wParam, LPARAM lParam)
{
  tvw_capture* capture = activeCapture.load();
  if (code >= 0 && capture) {
    const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    BYTE vkey = (BYTE)key->vkCode;
    bool intercept = true;

    // Windows stops updating the global keyboard state if we intercept
    // the key events. So we need to let some of them through to not
    // break things too badly.

    // Keys that were pressed when we started intercepting things must
    // be allowed to return to their neutral state
    if (((wParam == WM_KEYUP) || (wParam == WM_SYSKEYUP)) && (capture->state[vkey] & 0x80)) {
      intercept = false;
      // This key has been handled, so intercept further events
      capture->state[vkey] &= ~0x80;
    }

    // We can't modify the global lock key state, so we have no choice
    // but to let these through
    if ((vkey == VK_CAPITAL) || (vkey == VK_NUMLOCK) || (vkey == VK_SCROLL))
      intercept = false;

    // Never capture for a window that has lost the foreground; the host
    // stops capture on deactivation, this closes the race.
    if (intercept && GetForegroundWindow() != GetAncestor(capture->target, GA_ROOT))
      intercept = false;

    if (intercept) {
      PostMessageW(capture->target, (UINT)wParam, vkey, (LPARAM)((key->scanCode & 0xff) << 16 | (key->flags & 0xff) << 24));
      return 1;
    }
  }
  return CallNextHookEx(nullptr, code, wParam, lParam);
}

DWORD WINAPI captureThread(void* parameter)
{
  auto* capture = static_cast<tvw_capture*>(parameter);
  MSG msg;

  // Make sure a message queue is created
  PeekMessageW(&msg, nullptr, 0, 0, PM_NOREMOVE | PM_NOYIELD);

  // We need to know which keys are currently pressed
  for (int vkey = 1; vkey < 256; vkey++)
    capture->state[vkey] = (GetAsyncKeyState(vkey) & 0x8000) ? 0x80 : 0;

  HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, lowLevelProc, GetModuleHandleW(nullptr), 0);
  capture->status = hook ? S_OK : HRESULT_FROM_WIN32(GetLastError());
  if (hook)
    activeCapture.store(capture);
  SetEvent(capture->ready);
  if (!hook)
    return 0;

  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
  }

  activeCapture.store(nullptr);
  UnhookWindowsHookEx(hook);
  return 0;
}

} // namespace

extern "C" {

int32_t tvw_hook_install(tvw_hook_callback callback, void* context, tvw_hook** out)
{
  if (!callback || !out)
    return E_POINTER;
  *out = nullptr;
  if (currentHook)
    return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
  auto* hook = new (std::nothrow) tvw_hook();
  if (!hook)
    return E_OUTOFMEMORY;
  hook->thread = GetCurrentThreadId();
  hook->callback = callback;
  hook->context = context;
  hook->hook = SetWindowsHookExW(WH_GETMESSAGE, getMessageProc, nullptr, hook->thread);
  if (!hook->hook) {
    HRESULT error = HRESULT_FROM_WIN32(GetLastError());
    delete hook;
    return error;
  }
  currentHook = hook;
  *out = hook;
  return S_OK;
}

void tvw_hook_enable(tvw_hook* hook, uint32_t enabled)
{
  if (hook)
    hook->enabled = enabled != 0;
}

void tvw_hook_remove(tvw_hook* hook)
{
  if (!hook)
    return;
  if (currentHook == hook)
    currentHook = nullptr;
  UnhookWindowsHookEx(hook->hook);
  delete hook;
}

int32_t tvw_capture_start(uint64_t target_hwnd, tvw_capture** out)
{
  if (!out)
    return E_POINTER;
  *out = nullptr;
  HWND target = reinterpret_cast<HWND>(static_cast<uintptr_t>(target_hwnd));
  if (!IsWindow(target))
    return E_INVALIDARG;
  if (GetWindowThreadProcessId(target, nullptr) != GetCurrentThreadId())
    return RPC_E_WRONG_THREAD;
  if (!currentHook)
    return E_NOT_VALID_STATE; // The UI-thread hook repairs the keyboard state.
  if (activeCapture.load())
    return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
  auto* capture = new (std::nothrow) tvw_capture();
  if (!capture)
    return E_OUTOFMEMORY;
  capture->target = target;
  capture->uiThread = GetCurrentThreadId();
  // We create a separate thread as it is crucial that hooks are processed
  // in a timely manner.
  capture->ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (capture->ready)
    capture->thread = CreateThread(nullptr, 0, captureThread, capture, 0, &capture->threadId);
  HRESULT status = capture->thread ? S_OK : HRESULT_FROM_WIN32(GetLastError());
  if (capture->thread) {
    WaitForSingleObject(capture->ready, INFINITE);
    status = capture->status;
  }
  if (FAILED(status)) {
    tvw_capture_stop(capture);
    return status;
  }
  *out = capture;
  return S_OK;
}

void tvw_capture_stop(tvw_capture* capture)
{
  if (!capture)
    return;
  if (capture->thread) {
    PostThreadMessageW(capture->threadId, WM_QUIT, 0, 0);
    WaitForSingleObject(capture->thread, INFINITE);
    CloseHandle(capture->thread);
  }
  if (capture->ready)
    CloseHandle(capture->ready);
  delete capture;
}

} // extern "C"
