// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct TrustDetailsView: View {
  let request: NativePrompt
  let destination: String
  var inspection: NativeLegacyTrustMatch? = nil
  var saved: NativeSavedTrustInspection? = nil
  var issue: String? = nil
  var isWorking = false
  private var details: NativeTrustPresentation { NativeTrustPresentation(request) }
  var body: some View {
    let details = details
    VStack(alignment: .leading, spacing: 12) {
      if !destination.isEmpty && destination != request.serverName {
        LabeledContent("Destination", value: destination).textSelection(.enabled)
      }
      if isWorking { ProgressView("Checking saved certificate exceptions…").controlSize(.small) }
      if let issue { Text(issue).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      if let saved, saved.state != .absent {
        if saved.state == .changed {
          Text("The server public key differs from the key saved for this destination.").foregroundStyle(.red)
            .fixedSize(horizontal: false,vertical: true).accessibilityIdentifier("trust.changedScopedKey")
          Text("Expected " + (request.kind == .hostKey ? "Server-key SHA-256: " : "SPKI SHA-256: ") + (saved.expectedFingerprint ?? ""))
            .font(.system(.caption,design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
          Text("Received " + (request.kind == .hostKey ? "Server-key SHA-256: " : "SPKI SHA-256: ") + saved.receivedFingerprint)
            .font(.system(.caption,design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
        } else if saved.state == .forgotten {
          Text(request.kind == .hostKey ? "The server key was forgotten for this destination. Compare its fingerprint again before continuing." : "The saved key was forgotten for this destination. Older host-wide exceptions will not be reused here.")
            .font(.caption).fixedSize(horizontal: false,vertical: true)
        }
        Text("This decision is scoped to the destination’s address, port and route.").font(.caption).foregroundStyle(.secondary)
      }
      if let inspection {
        if inspection.state == .changed {
          Text("The server public key differs from the saved certificate exception.")
            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("trust.changedKey")
          ForEach(inspection.expectedIdentities, id: \.self) { identity in
            Text("Expected " + identity).font(.system(.caption, design: .monospaced))
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          Text("Received SPKI SHA-256: " + inspection.receivedSPKIFingerprint)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          if inspection.hasMoreIdentities { Text("Additional saved identities are not shown.").font(.caption) }
        } else if inspection.state == .missing {
          Text("No active saved certificate exception matches this server.").font(.caption)
        }
        Text(inspection.includesWildcardHost ? "The existing exception file includes a wildcard host rule." : "Existing certificate exceptions are scoped to the server name across ports and routes.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(details.problems.enumerated()), id: \.offset) { _, problem in
        Text(problem).fixedSize(horizontal: false, vertical: true)
      }
      if request.kind == .hostKey, let key = try? NativeHostKey(request.identity) { Text("RSA server key: \(key.bits) bits").font(.caption).foregroundStyle(.secondary) }
      if let subject = details.subject {
        LabeledContent("Certificate subject", value: subject).textSelection(.enabled)
      }
      if let fingerprint = details.sha256Fingerprint {
        Text(request.kind == .certificate ? "Certificate SHA-256 fingerprint" : "Server-key SHA-256 fingerprint")
          .font(.caption).foregroundStyle(.secondary)
        Text(fingerprint).font(.system(.caption, design: .monospaced))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("trust.sha256")
      }
      if let fingerprint = details.compatibilityFingerprint {
        Text("Server compatibility fingerprint (truncated SHA-1)").font(.caption).foregroundStyle(.secondary)
        Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .accessibilityIdentifier("trust.compatibilityFingerprint")
      }
      if details.mayConnectOnce {
        if request.kind == .certificate {
          Text("Verify this fingerprint with the server administrator before continuing.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("Connect Once applies only to this connection attempt. It does not save a trust exception.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("This identity cannot be accepted. Cancel and contact the server administrator.")
          .foregroundStyle(.red).accessibilityIdentifier("trust.cannotOverride")
      }
    }
  }
}
