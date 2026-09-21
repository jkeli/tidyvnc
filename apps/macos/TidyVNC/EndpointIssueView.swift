// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func endpointMessage(_ issue: NativeEndpointIssue) -> String {
  switch issue {
  case .required: return "Enter a server address."
  case .tooLong: return "The server address is too long (maximum 4096 UTF-8 bytes)."
  case .invalidHost: return "Check the host name or IP address. Put IPv6 addresses in brackets when adding a display number or port."
  case .unmatchedBracket: return "Add the closing bracket after the IPv6 address or host name."
  case .invalidPort: return "Use host:display or host::port. The port must be between 1 and 65535."
  case .invalidPath: return "The Unix socket path contains invalid text."
  case .invalidRoute: return "The connection route is invalid."
  case .unsupportedTransport: return "Unix socket connections are unavailable for this connection."
  case .invalidText: return "The server address contains invalid text. Check the address and try again."
  case .unavailable: return "The server address could not be checked. Try again."
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
