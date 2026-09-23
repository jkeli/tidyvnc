# Native viewer accessibility and remote-framebuffer limits (N4.17)

Recorded 2026-09-23. Evidence for labels is in
[UI-ACCEPTANCE.md](UI-ACCEPTANCE.md) (automated label audit of 26 screens); a
VoiceOver listening pass, keyboard traversal and a high-contrast review remain
open in [TODO.md](TODO.md).

## What the native app exposes

- **Local UI.** The connection window, its sheets, Settings, the trust and
  profile libraries, import windows, Help and About are native SwiftUI/AppKit
  controls. Every interactive control reached by the audit exposes a spoken
  label, and the toolbar's icon-only buttons have explicit labels and help text.
- **Remote desktop.** `NativeDesktopView` is one accessibility element with role
  *image*, the label "Remote desktop" and help "Click to focus. Keyboard and
  pointer input control the connected computer." Its custom actions are *Focus
  remote desktop* plus *Pan* left, right, up, down and to the origin, offered
  only while panning is possible. When pan availability changes, the view posts
  a layout-changed notification.
- **Status.** Connection, fullscreen, keyboard-capture, remote-resize and
  clipboard status texts carry stable identifiers. Connection statistics are an
  optional passive overlay.
- **Motion.** The app defines no custom animations or transitions; system
  animations follow the Reduce Motion setting.
- **Colour contrast.** Warning and error text uses `Color.nativeWarningText` and
  `Color.nativeErrorText` (`platform/macos/Presentation/NativeStatusColors.swift`)
  rather than system orange and red. System orange measured 1.79:1 on a light
  sheet, below WCAG AA. The replacement colours are at least 4.5:1 on window,
  control and text backgrounds in light and dark, and at least 6:1 in the
  high-contrast appearances; `NativePresentation.StructuredRecoveryAndRedaction` checks this. The
  rendered light-mode warning measures 4.94:1. Offscreen renders do not apply
  the high-contrast appearance, so what Increase Contrast actually looks like
  still needs an on-device look.

## Remote framebuffer limits (inherent to RFB)

- The remote desktop is a stream of pixels. The viewer receives no text, window,
  control or focus information from the server, so VoiceOver cannot read or
  navigate the remote computer's interface. It announces only the image element
  and its actions. The retained FLTK viewer has the same limit, and TidyVNC does
  not add OCR.
- Screen-reader users need assistive technology running **on the remote
  computer**, with its speech or braille output local to that computer. Audio
  is not carried by RFB.
- Remote pointer position and remote cursor shape are visual only. The local
  pointer fallback (hidden, dot or system) can be chosen per connection.
- Zoom and other local magnification work on the displayed pixels. The scaling
  modes and filters in the Scaling sheet change how the framebuffer is resampled,
  not what the remote interface renders.

## Keyboard interaction with assistive technology

- While the remote desktop has focus, keystrokes go to the remote computer.
  Viewer commands use shortcut modifiers, **Control + Option by default**,
  configurable in Input settings: pressing them alone releases keyboard capture;
  with G they capture the keyboard, with M they open the connection menu, and
  with Return they toggle full screen.
- Control + Option is also the default VoiceOver modifier. VoiceOver users
  should pick different viewer shortcut modifiers, or rely on the VoiceOver
  modifier being handled by the system first. How system-key capture in full
  screen interacts with VoiceOver has **not** been verified; it belongs to the
  open VoiceOver pass.
- The accessibility API cannot set the address field's text through AXValue:
  SwiftUI does not propagate it to the binding. Keyboard typing, including
  typing with VoiceOver running, uses normal text input rather than AXValue.
