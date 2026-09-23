// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct SecuritySettingsFields: View {
  @Binding var patch: NativeSecurityPreferences
  let inherited: NativeSecuritySelection
  let choices: [NativeSecurityChoice]
  let inheritance: String
  var inheritedPriority: String = ""
  var scopeMessage = String(localized:"settings.security.allow.the.methods.your.server.may.negotiate.the.server.s.offer.order", defaultValue:"Allow the methods your server may negotiate. The server’s offer order determines the choice. Changes apply to new connection windows.")
  private var selected: NativeSecuritySelection? { patch.types == nil ? inherited : try? patch.selection() }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DisclosureGroup(String(localized:"settings.security.advanced.tls.priority", defaultValue:"Advanced TLS Priority")) {
        TLSPrioritySettingsFields(patch:$patch,inheritedPriority:inheritedPriority,inheritance:inheritance,
          available:choices.contains { $0.protection == .x509TLS && $0.available })
      }
      Toggle(String(localized:"settings.security.override.allowed.security.methods", defaultValue:"Override allowed security methods"),isOn:Binding(get: { patch.types != nil },set: {
        patch.types = $0 ? inherited.canonical : nil
      })).accessibilityIdentifier("security.override")
      Text(patch.types == nil ? inheritance : String(localized:"settings.security.explicit.selection", defaultValue:"Explicit selection"))
        .font(.caption).foregroundStyle(.secondary)
      Text(scopeMessage)
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if selected?.types.isEmpty == true {
        Text(String(localized:"settings.security.no.methods.are.allowed.new.connections.will.be.refused", defaultValue:"No methods are allowed. New connections will be refused."))
          .foregroundStyle(Color.nativeWarningText).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("security.empty")
      } else if selected == nil { Text(String(localized:"settings.security.the.security.selection.is.invalid.or.unavailable.in.this.build", defaultValue:"The security selection is invalid or unavailable in this build.")).foregroundStyle(Color.nativeErrorText) }
      ForEach(NativeSecurityChoice.Protection.allCases,id:\.self) { group in
        GroupBox(title(group)) {
          VStack(alignment:.leading,spacing:8) {
            if group == .rsaAuthentication || group == .legacyAuthentication {
              Text(String(localized:"settings.security.desktop.traffic.remains.unencrypted", defaultValue:"Desktop traffic remains unencrypted.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(choices.filter { $0.protection == group }) { choice in
              Toggle(isOn:Binding(get: { selected?.types.contains(choice.id) == true },set: { set(choice,$0) })) {
                VStack(alignment:.leading,spacing:2) {
                  Text(choice.name)
                  Text(choice.available ? details(choice) : String(localized:"settings.security.unavailable.in.this.build", defaultValue:"Unavailable in this build"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
              }.disabled(patch.types == nil || !choice.available || selected == nil)
                .accessibilityIdentifier("security.method.\(choice.name)")
            }
          }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
        }
      }
    }
  }
  private func set(_ choice: NativeSecurityChoice, _ enabled: Bool) {
    guard patch.types != nil, choice.available, let selected else { return }
    var tokens = selected.canonical.isEmpty ? [] : selected.canonical.components(separatedBy:",")
    tokens.removeAll { $0 == choice.name }; if enabled { tokens.append(choice.name) }
    patch.types = tokens.joined(separator:",")
  }
  private func title(_ group: NativeSecurityChoice.Protection) -> String {
    switch group {
    case .unencrypted: String(localized:"settings.security.unencrypted.session", defaultValue:"Unencrypted session")
    case .anonymousTLS: String(localized:"settings.security.tls.without.server.identity.verification", defaultValue:"TLS without server identity verification")
    case .x509TLS: String(localized:"settings.security.tls.with.x509.certificate.verification", defaultValue:"TLS with X509 certificate verification")
    case .rsaAES: String(localized:"settings.security.rsa.aes.session.encryption", defaultValue:"RSA-AES session encryption")
    case .rsaAuthentication: String(localized:"settings.security.rsa.aes.authentication.only", defaultValue:"RSA-AES authentication only")
    case .legacyAuthentication: String(localized:"settings.security.legacy.authentication.only", defaultValue:"Legacy authentication only")
    }
  }
  private func details(_ choice: NativeSecurityChoice) -> String {
    let authentication: String
    switch choice.credentials {
    case .none: authentication = String(localized:"settings.security.no.user.authentication", defaultValue:"No user authentication")
    case .password: authentication = String(localized:"settings.security.vnc.password", defaultValue:"VNC password")
    case .usernamePassword: authentication = String(localized:"settings.security.username.and.password", defaultValue:"Username and password")
    case .serverSelected: authentication = String(localized:"settings.security.server.selects.password.or.username.and.password", defaultValue:"Server selects password or username and password")
    }
    return choice.aesBits == 0 ? authentication : String(localized:"settings.security.aes.authentication", defaultValue:"\(choice.aesBits.formatted())-bit AES · \(authentication)")
  }
}

struct TLSPrioritySettingsFields: View {
  @Binding var patch: NativeSecurityPreferences
  let inheritedPriority: String, inheritance: String
  let available: Bool
  var body: some View {
        VStack(alignment:.leading,spacing:8) {
          Toggle(String(localized:"settings.security.override.tls.priority", defaultValue:"Override TLS priority"),isOn:Binding(get: { patch.tlsPriority != nil },set: {
            patch.tlsPriority = $0 ? inheritedPriority : nil
          })).accessibilityIdentifier("security.priority.override")
          TextField(String(localized:"settings.security.library.default.empty", defaultValue:"Library default (empty)"),text:Binding(get: { patch.tlsPriority ?? inheritedPriority },set: { patch.tlsPriority = $0 }))
            .disabled(patch.tlsPriority == nil || !available).accessibilityIdentifier("security.priority.expression")
          if patch.tlsPriority != nil {
            Button(String(localized:"settings.security.use.library.default", defaultValue:"Use Library Default")) { patch.tlsPriority = "" }
          }
          Text(patch.tlsPriority == nil ? inheritance : patch.tlsPriority == "" ? String(localized:"settings.security.library.default", defaultValue:"Library default") : String(localized:"settings.security.custom.tls.priority", defaultValue:"Custom TLS priority"))
            .font(.caption).foregroundStyle(.secondary)
          Text(String(localized:"settings.security.applies.to.tls.methods.when.connecting.gnutls.expressions.are.checked.on.apply", defaultValue:"Applies to TLS methods when connecting. GnuTLS expressions are checked on Apply or Save; the server must support the chosen algorithms and TLS versions."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
          if !patch.isPriorityTextValid { Text(String(localized:"settings.security.use.at.most.4096.utf.8.bytes.with.no.nul.characters", defaultValue:"Use at most 4096 UTF-8 bytes with no NUL characters.")).foregroundStyle(Color.nativeErrorText) }
          if !available {
            Text(String(localized:"settings.security.custom.tls.priorities.are.unavailable.in.this.build.use.the.library.default", defaultValue:"Custom TLS priorities are unavailable in this build. Use the library default or inherit.")).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(8)
  }
}
