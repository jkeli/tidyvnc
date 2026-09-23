// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Presentation is selected only by typed failures and the operation being shown.
// Never retain or stringify error descriptions, NSError userInfo, paths, endpoints
// or remote payloads. Callers retain their existing cancellation/lifetime guards.
public enum NativePresentationIssue: Sendable, Equatable, CaseIterable {
  public enum Context: Sendable, Equatable, CaseIterable { case startup, desktop, cursor, layout, input, shortcut, fullscreen, command }
  case startupUnavailable, startupIncompatible, startupResources, preferencesUnavailable, desktopUnavailable, desktopResources, cursorUnavailable, layoutUnavailable, layoutResources, displaysUnavailable, inputUnavailable, inputBusy, inputFailed, shortcutUnavailable, keyboardCaptureUnavailable, fullscreenUnavailable, commandUnavailable
  public init(error: any Error, context: Context) {
    let status = (error as? NativeError)?.status
    let limited = status == .resourceLimit || status == .outOfMemory
    if context == .startup {
      if error is NativePreferencesError { self = .preferencesUnavailable }
      else if status == .abiMismatch || status == .unsupported { self = .startupIncompatible }
      else { self = limited ? .startupResources : .startupUnavailable }
      return
    }
    if (error as? NativeDesktopCommandIssue) == .keyboardCaptureUnavailable {
      self = .keyboardCaptureUnavailable; return
    }
    if let display = error as? NativeDisplayError {
      self = display == .tooManyDisplays ? .layoutResources : .displaysUnavailable; return
    }
    switch context {
    case .startup: self = .startupUnavailable // Handled above.
    case .desktop: self = limited ? .desktopResources : .desktopUnavailable
    case .cursor: self = .cursorUnavailable
    case .layout: self = limited ? .layoutResources : .layoutUnavailable
    case .fullscreen: self = limited ? .layoutResources : .fullscreenUnavailable
    case .input, .shortcut, .command:
      switch status {
      case .notConnected, .viewOnly, .unfocused, .disabled: self = .inputUnavailable
      case .busy, .queueFull: self = .inputBusy
      default:
        switch context {
        case .shortcut: self = .shortcutUnavailable
        case .command: self = .commandUnavailable
        default: self = .inputFailed
        }
      }
    }
  }
  public var message: String {
    switch self {
    case .startupUnavailable: return String(localized:"presentation.issue.startupUnavailable", defaultValue:"TidyVNC could not start the native viewer. Reopen the app. If the problem persists, install a compatible build of TidyVNC.")
    case .startupIncompatible: return String(localized:"presentation.issue.startupIncompatible", defaultValue:"The native viewer components are incompatible or lack a required feature. Install a matching build of TidyVNC.")
    case .startupResources: return String(localized:"presentation.issue.startupResources", defaultValue:"TidyVNC could not allocate resources to start. Close unused applications and reopen TidyVNC.")
    case .preferencesUnavailable: return String(localized:"presentation.issue.preferencesUnavailable", defaultValue:"TidyVNC could not open its settings store. Reopen the app and check that your macOS account can access its preferences.")
    case .desktopUnavailable: return String(localized:"presentation.issue.desktopUnavailable", defaultValue:"The remote desktop could not be drawn. Try Refresh Desktop. If it still does not update, reconnect.")
    case .desktopResources: return String(localized:"presentation.issue.desktopResources", defaultValue:"The desktop exceeds available rendering resources. Reduce the window size or scale in Scaling Settings, or close unused connections.")
    case .cursorUnavailable: return String(localized:"presentation.issue.cursorUnavailable", defaultValue:"The remote cursor could not be drawn. The local pointer is being used. Reconnect if the cursor remains unavailable.")
    case .layoutUnavailable: return String(localized:"presentation.issue.layoutUnavailable", defaultValue:"The desktop layout could not be changed. Review Scaling Settings and Fullscreen Displays, then try again.")
    case .layoutResources: return String(localized:"presentation.issue.layoutResources", defaultValue:"The display layout exceeds available resources. Select fewer displays, reduce the scale or close unused connections, then try again.")
    case .displaysUnavailable: return String(localized:"presentation.issue.displaysUnavailable", defaultValue:"The display arrangement is unavailable. Reconnect any missing displays and review Fullscreen Displays.")
    case .inputUnavailable: return String(localized:"presentation.issue.inputUnavailable", defaultValue:"Focus the desktop and check view-only and input settings before trying again.")
    case .inputBusy: return String(localized:"presentation.issue.inputBusy", defaultValue:"Keyboard or pointer input is busy. Release pressed keys, wait for the current operation to finish and try again.")
    case .inputFailed: return String(localized:"presentation.issue.inputFailed", defaultValue:"Keyboard or pointer input could not be sent. Release pressed keys, focus the desktop and try again. Reconnect if input remains unavailable.")
    case .shortcutUnavailable: return String(localized:"presentation.issue.shortcutUnavailable", defaultValue:"This keyboard shortcut could not be completed. Release pressed keys and try again. Review Input Settings if it keeps failing.")
    case .keyboardCaptureUnavailable: return String(localized:"desktop.keyboard.capture.is.unavailable.allow.tidyvnc.in.macos.accessibility.settings.and.try", defaultValue:"Keyboard capture is unavailable. Allow TidyVNC in macOS Accessibility settings and try again.")
    case .fullscreenUnavailable: return String(localized:"desktop.fullscreen.full.screen.could.not.be.opened.review.fullscreen.displays.or.use.enter", defaultValue:"Full screen could not be opened. Review Fullscreen Displays or use Enter Full Screen to try again.")
    case .commandUnavailable: return String(localized:"connection.recovery.this.desktop.command.is.unavailable.focus.the.connected.desktop.and.try.again", defaultValue:"This desktop command is unavailable. Focus the connected desktop and try again.")
    }
  }
}
