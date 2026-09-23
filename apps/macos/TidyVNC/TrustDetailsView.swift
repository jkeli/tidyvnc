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
        LabeledContent(String(localized:"trust.destination", defaultValue:"Destination"), value: destination).textSelection(.enabled)
      }
      if isWorking { ProgressView(String(localized:"trust.checking.saved.certificate.exceptions", defaultValue:"Checking saved certificate exceptions…")).controlSize(.small) }
      if let issue { Text(issue).foregroundStyle(Color.nativeWarningText).fixedSize(horizontal: false, vertical: true) }
      if let saved, saved.state != .absent {
        if saved.state == .changed {
          Text(String(localized:"trust.the.server.public.key.differs.from.the.key.saved.for.this.destination", defaultValue:"The server public key differs from the key saved for this destination.")).foregroundStyle(Color.nativeErrorText)
            .fixedSize(horizontal: false,vertical: true).accessibilityIdentifier("trust.changedScopedKey")
          Text(request.kind == .hostKey ? String(localized:"trust.expected.serverKey", defaultValue:"Expected Server-key SHA-256: \(saved.expectedFingerprint ?? "")") : String(localized:"trust.expected.spki", defaultValue:"Expected SPKI SHA-256: \(saved.expectedFingerprint ?? "")"))
            .font(.system(.caption,design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
          Text(request.kind == .hostKey ? String(localized:"trust.received.serverKey", defaultValue:"Received Server-key SHA-256: \(saved.receivedFingerprint)") : String(localized:"trust.received.spki", defaultValue:"Received SPKI SHA-256: \(saved.receivedFingerprint)"))
            .font(.system(.caption,design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
        } else if saved.state == .forgotten {
          Text(request.kind == .hostKey ? String(localized:"trust.the.server.key.was.forgotten.for.this.destination.compare.its.fingerprint.again", defaultValue:"The server key was forgotten for this destination. Compare its fingerprint again before continuing.") : String(localized:"trust.the.saved.key.was.forgotten.for.this.destination.older.host.wide.exceptions", defaultValue:"The saved key was forgotten for this destination. Older host-wide exceptions will not be reused here."))
            .font(.caption).fixedSize(horizontal: false,vertical: true)
        }
        Text(String(localized:"trust.this.decision.is.scoped.to.the.destination.s.address.port.and.route", defaultValue:"This decision is scoped to the destination’s address, port and route.")).font(.caption).foregroundStyle(.secondary)
      }
      if let inspection {
        if inspection.state == .changed {
          Text(String(localized:"trust.the.server.public.key.differs.from.the.saved.certificate.exception", defaultValue:"The server public key differs from the saved certificate exception."))
            .foregroundStyle(Color.nativeErrorText).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("trust.changedKey")
          ForEach(inspection.expectedIdentities, id: \.self) { identity in
            Text(identity.expectedMessage).font(.system(.caption, design: .monospaced))
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          Text(String(localized:"trust.received.spki", defaultValue:"Received SPKI SHA-256: \(inspection.receivedSPKIFingerprint)"))
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          if inspection.hasMoreIdentities { Text(String(localized:"trust.additional.saved.identities.are.not.shown", defaultValue:"Additional saved identities are not shown.")).font(.caption) }
        } else if inspection.state == .missing {
          Text(String(localized:"trust.no.active.saved.certificate.exception.matches.this.server", defaultValue:"No active saved certificate exception matches this server.")).font(.caption)
        }
        Text(inspection.includesWildcardHost ? String(localized:"trust.the.existing.exception.file.includes.a.wildcard.host.rule", defaultValue:"The existing exception file includes a wildcard host rule.") : String(localized:"trust.existing.certificate.exceptions.are.scoped.to.the.server.name.across.ports.and", defaultValue:"Existing certificate exceptions are scoped to the server name across ports and routes."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(details.problems.enumerated()), id: \.offset) { _, problem in
        Text(problem).fixedSize(horizontal: false, vertical: true)
      }
      if request.kind == .hostKey, let key = try? NativeHostKey(request.identity) { Text(String(localized:"trust.rsa.bits", defaultValue:"RSA server key: \(key.bits) bits")).font(.caption).foregroundStyle(.secondary) }
      if let subject = details.subject {
        LabeledContent(String(localized:"trust.certificate.subject", defaultValue:"Certificate subject"), value: subject).textSelection(.enabled)
      }
      if let fingerprint = details.sha256Fingerprint {
        Text(request.kind == .certificate ? String(localized:"trust.certificate.sha.256.fingerprint", defaultValue:"Certificate SHA-256 fingerprint") : String(localized:"trust.server.key.sha.256.fingerprint", defaultValue:"Server-key SHA-256 fingerprint"))
          .font(.caption).foregroundStyle(.secondary)
        Text(fingerprint).font(.system(.caption, design: .monospaced))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("trust.sha256")
      }
      if let fingerprint = details.compatibilityFingerprint {
        Text(String(localized:"trust.server.compatibility.fingerprint.truncated.sha.1", defaultValue:"Server compatibility fingerprint (truncated SHA-1)")).font(.caption).foregroundStyle(.secondary)
        Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .accessibilityIdentifier("trust.compatibilityFingerprint")
      }
      if details.mayConnectOnce {
        if request.kind == .certificate {
          Text(String(localized:"trust.verify.this.fingerprint.with.the.server.administrator.before.continuing", defaultValue:"Verify this fingerprint with the server administrator before continuing."))
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(String(localized:"trust.connect.once.applies.only.to.this.connection.attempt.it.does.not.save", defaultValue:"Connect Once applies only to this connection attempt. It does not save a trust exception."))
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text(String(localized:"trust.this.identity.cannot.be.accepted.cancel.and.contact.the.server.administrator", defaultValue:"This identity cannot be accepted. Cancel and contact the server administrator."))
          .foregroundStyle(Color.nativeErrorText).accessibilityIdentifier("trust.cannotOverride")
      }
      // Secondary details follow the fingerprint and its guidance, which must stay in view.
      if let certificate = details.certificate {
        if let issuer = certificate.issuer {
          LabeledContent(String(localized:"trust.certificate.issuer", defaultValue:"Issuer"), value: issuer).textSelection(.enabled)
        }
        if let serial = certificate.serialNumber {
          LabeledContent(String(localized:"trust.certificate.serial", defaultValue:"Serial number")) {
            Text(serial).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          }
        }
        if let from = certificate.validFrom {
          LabeledContent(String(localized:"trust.certificate.valid.from", defaultValue:"Valid from")) { Text(from, format: .dateTime) }
        }
        if let until = certificate.validUntil {
          LabeledContent(String(localized:"trust.certificate.valid.until", defaultValue:"Valid until")) { Text(until, format: .dateTime) }
        }
        if let algorithm = certificate.keyAlgorithm, let bits = certificate.keyBits {
          LabeledContent(String(localized:"trust.certificate.public.key", defaultValue:"Public key"),
                         value: String(localized:"trust.certificate.public.key.value", defaultValue:"\(algorithm), \(bits) bits"))
        }
        if let signature = certificate.signatureAlgorithm {
          LabeledContent(String(localized:"trust.certificate.signature", defaultValue:"Signature algorithm"), value: signature)
        }
      }
    }
  }
}
