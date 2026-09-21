// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct SecuritySettingsFields: View {
  @Binding var patch: NativeSecurityPreferences
  let inherited: NativeSecuritySelection
  let choices: [NativeSecurityChoice]
  let inheritance: String
  var inheritedPriority: String = ""
  var scopeMessage = "Allow the methods your server may negotiate. The server’s offer order determines the choice. Changes apply to new connection windows."
  private var selected: NativeSecuritySelection? { patch.types == nil ? inherited : try? patch.selection() }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DisclosureGroup("Advanced TLS Priority") {
        TLSPrioritySettingsFields(patch:$patch,inheritedPriority:inheritedPriority,inheritance:inheritance,
          available:choices.contains { $0.protection == .x509TLS && $0.available })
      }
      Toggle("Override allowed security methods",isOn:Binding(get: { patch.types != nil },set: {
        patch.types = $0 ? inherited.canonical : nil
      })).accessibilityIdentifier("security.override")
      Text(patch.types == nil ? inheritance : "Explicit selection")
        .font(.caption).foregroundStyle(.secondary)
      Text(scopeMessage)
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      if selected?.types.isEmpty == true {
        Text("No methods are allowed. New connections will be refused.")
          .foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("security.empty")
      } else if selected == nil { Text("The security selection is invalid or unavailable in this build.").foregroundStyle(.red) }
      ForEach(NativeSecurityChoice.Protection.allCases,id:\.self) { group in
        GroupBox(title(group)) {
          VStack(alignment:.leading,spacing:8) {
            if group == .rsaAuthentication || group == .legacyAuthentication {
              Text("Desktop traffic remains unencrypted.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(choices.filter { $0.protection == group }) { choice in
              Toggle(isOn:Binding(get: { selected?.types.contains(choice.id) == true },set: { set(choice,$0) })) {
                VStack(alignment:.leading,spacing:2) {
                  Text(choice.name)
                  Text(choice.available ? details(choice) : "Unavailable in this build")
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
    case .unencrypted: "Unencrypted session"
    case .anonymousTLS: "TLS without server identity verification"
    case .x509TLS: "TLS with X509 certificate verification"
    case .rsaAES: "RSA-AES session encryption"
    case .rsaAuthentication: "RSA-AES authentication only"
    case .legacyAuthentication: "Legacy authentication only"
    }
  }
  private func details(_ choice: NativeSecurityChoice) -> String {
    let authentication: String
    switch choice.credentials {
    case .none: authentication = "No user authentication"
    case .password: authentication = "VNC password"
    case .usernamePassword: authentication = "Username and password"
    case .serverSelected: authentication = "Server selects password or username and password"
    }
    return choice.aesBits == 0 ? authentication : "\(choice.aesBits)-bit AES · \(authentication)"
  }
}

struct TLSPrioritySettingsFields: View {
  @Binding var patch: NativeSecurityPreferences
  let inheritedPriority: String, inheritance: String
  let available: Bool
  var body: some View {
        VStack(alignment:.leading,spacing:8) {
          Toggle("Override TLS priority",isOn:Binding(get: { patch.tlsPriority != nil },set: {
            patch.tlsPriority = $0 ? inheritedPriority : nil
          })).accessibilityIdentifier("security.priority.override")
          TextField("Library default (empty)",text:Binding(get: { patch.tlsPriority ?? inheritedPriority },set: { patch.tlsPriority = $0 }))
            .disabled(patch.tlsPriority == nil || !available).accessibilityIdentifier("security.priority.expression")
          if patch.tlsPriority != nil {
            Button("Use Library Default") { patch.tlsPriority = "" }
          }
          Text(patch.tlsPriority == nil ? inheritance : patch.tlsPriority == "" ? "Library default" : "Custom TLS priority")
            .font(.caption).foregroundStyle(.secondary)
          Text("Applies to TLS methods when connecting. GnuTLS expressions are checked on Apply or Save; the server must support the chosen algorithms and TLS versions.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
          if !patch.isPriorityTextValid { Text("Use at most 4096 UTF-8 bytes with no NUL characters.").foregroundStyle(.red) }
          if !available {
            Text("Custom TLS priorities are unavailable in this build. Use the library default or inherit.").font(.caption).foregroundStyle(.secondary)
          }
        }.padding(8)
  }
}
