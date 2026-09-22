// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func endpointMessage(_ issue: NativeEndpointIssue) -> String {
  switch issue {
  case .required: return String(localized:"endpoint.issue.enter.a.server.address", defaultValue:"Enter a server address.")
  case .tooLong: return String(localized:"endpoint.issue.the.server.address.is.too.long.maximum.4096.utf.8.bytes", defaultValue:"The server address is too long (maximum 4096 UTF-8 bytes).")
  case .invalidHost: return String(localized:"endpoint.issue.check.the.host.name.or.ip.address.put.ipv6.addresses.in.brackets", defaultValue:"Check the host name or IP address. Put IPv6 addresses in brackets when adding a display number or port.")
  case .unmatchedBracket: return String(localized:"endpoint.issue.add.the.closing.bracket.after.the.ipv6.address.or.host.name", defaultValue:"Add the closing bracket after the IPv6 address or host name.")
  case .invalidPort: return String(localized:"endpoint.issue.use.host.display.or.host.port.the.port.must.be.between.1", defaultValue:"Use host:display or host::port. The port must be between 1 and 65535.")
  case .invalidPath: return String(localized:"endpoint.issue.the.unix.socket.path.contains.invalid.text", defaultValue:"The Unix socket path contains invalid text.")
  case .invalidRoute: return String(localized:"endpoint.issue.the.connection.route.is.invalid", defaultValue:"The connection route is invalid.")
  case .unsupportedTransport: return String(localized:"endpoint.issue.unix.socket.connections.are.unavailable.for.this.connection", defaultValue:"Unix socket connections are unavailable for this connection.")
  case .invalidText: return String(localized:"endpoint.issue.the.server.address.contains.invalid.text.check.the.address.and.try.again", defaultValue:"The server address contains invalid text. Check the address and try again.")
  case .unavailable: return String(localized:"endpoint.issue.the.server.address.could.not.be.checked.try.again", defaultValue:"The server address could not be checked. Try again.")
  }
}
struct EndpointIssueView: View {
  let issue: NativeEndpointIssue?
  var body: some View {
    if let issue, issue != .required {
      Text(endpointMessage(issue)).font(.caption).foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("endpoint.validation")
    }
  }
}
