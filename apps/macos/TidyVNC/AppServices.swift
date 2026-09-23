// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

// Every service the app coordinator owns, chosen in one place. Production uses
// the platform stores; tests pass memory backings and fakes so the coordinator's
// own wiring (sessions, windows, quit) runs without touching user data.
@MainActor struct AppServices {
  var clipboard: NativeClipboardCoordinator
  var bell: any NativeBellSounding
  var displays: NativeDisplayService
  var credentials: NativeCredentialStore
  var legacyTrust: NativeLegacyTrustStore?
  var savedTrust: NativeTrustStore
  var savedHostKeys: NativeTrustStore
  var profiles: NativeProfileHistoryStore
  var environment: [String:String]
  var makeRuntime: () throws -> NativeRuntime
  var makePreferencesBacking: () throws -> any NativePreferencesBacking

  static func production() -> AppServices {
    AppServices(
      clipboard: NativeClipboardCoordinator(),
      bell: NativeSystemBell(),
      displays: NativeDisplayService(),
      credentials: NativeCredentialStore(),
      // An unusable path surfaces as an unavailable legacy store at trust review.
      legacyTrust: (try? NativeLegacyTrustFile.applicationStore()).map { NativeLegacyTrustStore(backing: $0) },
      savedTrust: NativeTrustStore(),
      savedHostKeys: NativeTrustStore(kind: .hostKey),
      profiles: NativeProfileHistoryStore(backing: NativeApplicationSupportProfiles()),
      environment: NativePathEnvironment.capture(),
      makeRuntime: { try NativeRuntime() },
      makePreferencesBacking: {
        let domain = (Bundle.main.bundleIdentifier ?? "io.github.jkeli.tidyvnc") + ".native.preferences"
        return try UserDefaultsPreferencesBacking(domain: domain)
      })
  }
}
