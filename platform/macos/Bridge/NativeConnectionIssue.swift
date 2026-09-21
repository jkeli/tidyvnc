// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import Darwin

// Only structured codes select UI text. Remote error strings, endpoints, paths
// and credential material never become part of this presentation value.
public enum NativeConnectionIssue: Sendable, Equatable, CaseIterable {
  case resolution, resolutionTimeout, refused, routing, networkPolicy, connectionTimeout
  case connection, transport, peerClosed, authenticationRejected, promptTimeout
  case protocolFailure, resource, internalFailure, unsupportedEndpoint, invalidEndpoint
  case unsupported, invalidRequest, busy, notConnected, inputUnavailable, operationTimeout, serverRejected, operationFailed

  public init?(snapshot: NativeSnapshot) {
    guard snapshot.state == .closed || snapshot.state == .failed else { return nil }
    switch snapshot.endReason {
    case .none, .cancelled: return nil
    case .resolution: self = .resolution
    case .resolutionTimeout: self = .resolutionTimeout
    case .connectionTimeout: self = .connectionTimeout
    case .connection, .transport:
      switch snapshot.nativeCode {
      case EACCES, EPERM: self = .networkPolicy
      case ECONNREFUSED: self = .refused
      case ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH: self = .routing
      case ETIMEDOUT: self = .connectionTimeout
      default: self = snapshot.endReason == .transport ? .transport : .connection
      }
    case .peerClosed: self = .peerClosed
    case .authenticationRejected: self = .authenticationRejected
    case .promptTimeout: self = .promptTimeout
    case .protocolFailure: self = .protocolFailure
    case .resource, .eventOverflow: self = .resource
    case .internalFailure: self = .internalFailure
    case .unsupportedEndpoint: self = .unsupportedEndpoint
    case .invalidEndpoint: self = .invalidEndpoint
    }
  }
  public init?(error: any Error) {
    if error is CancellationError { return nil }
    if let failure = error as? NativeCommandFailure {
      guard failure.result != .cancelled else { return nil }
      if let terminal = Self(snapshot: failure.snapshot) { self = terminal; return }
      switch failure.reason {
      case .timedOut: self = .operationTimeout
      case .serverRejected: self = .serverRejected
      case .none: self = .operationFailed
      }
    } else if let failure = error as? NativeError {
      switch failure.status {
      case .cancelled, .closing, .stale, .notPending: return nil
      case .unsupported: self = .unsupported
      case .invalidArgument: self = .invalidRequest
      case .busy, .queueFull: self = .busy
      case .notConnected: self = .notConnected
      case .viewOnly, .unfocused, .disabled: self = .inputUnavailable
      case .resourceLimit, .outOfMemory: self = .resource
      default: self = .internalFailure
      }
    } else { self = .internalFailure }
  }
  public var permitsReconnect: Bool {
    switch self {
    case .resolution, .resolutionTimeout, .refused, .routing, .networkPolicy,
         .connectionTimeout, .connection, .transport, .peerClosed,
         .authenticationRejected, .promptTimeout, .protocolFailure: return true
    default: return false
    }
  }
  public var title: String {
    switch self {
    case .resolution, .resolutionTimeout: return "Server Address Not Resolved"
    case .refused: return "Connection Refused"
    case .routing: return "Network Route Unavailable"
    case .networkPolicy: return "Connection Restricted"
    case .connectionTimeout: return "Connection Timed Out"
    case .connection: return "Unable to Connect"
    case .transport: return "Connection Interrupted"
    case .peerClosed: return "Server Closed the Connection"
    case .authenticationRejected: return "Authentication Rejected"
    case .promptTimeout: return "Authentication Timed Out"
    case .protocolFailure: return "Connection Protocol Error"
    case .resource: return "Connection Resource Limit"
    case .internalFailure: return "Connection Unavailable"
    case .unsupportedEndpoint, .unsupported: return "Unsupported Connection Feature"
    case .invalidEndpoint: return "Invalid Server Address"
    case .invalidRequest: return "Invalid Request"
    case .busy: return "Connection Busy"
    case .notConnected: return "Desktop Not Connected"
    case .inputUnavailable: return "Desktop Input Unavailable"
    case .operationTimeout: return "Request Timed Out"
    case .serverRejected: return "Request Rejected"
    case .operationFailed: return "Request Failed"
    }
  }
  public var message: String {
    switch self {
    case .resolution: return "Check the server name and your network or VPN connection, then try again."
    case .resolutionTimeout: return "Looking up the server address took too long. Check your network or VPN connection, then try again."
    case .refused: return "Check the port and that the server's VNC service is running and accepting connections."
    case .routing: return "Check your network, VPN and the route to the server."
    case .networkPolicy: return "Network or system policy may be preventing this connection. Check firewall and VPN settings. For a local server, also check TidyVNC under System Settings > Privacy & Security > Local Network. This error does not identify which policy blocked access."
    case .connectionTimeout: return "The server did not respond in time. Check its address, network connection and VNC service, then try again."
    case .connection: return "Check the server address, network connection and VNC service, then try again."
    case .transport: return "The connection to the server was interrupted. Check your network or VPN connection before reconnecting."
    case .peerClosed: return "The server ended this connection. Reconnect when the server is available."
    case .authenticationRejected: return "The server rejected authentication. Retry to enter your credentials again, and check that the server permits your authentication method."
    case .promptTimeout: return "The authentication request expired. Retry to start a new authentication request."
    case .protocolFailure: return "The server and viewer could not complete the VNC protocol exchange. Check server compatibility and security settings before retrying."
    case .resource: return "The connection exceeded an available resource limit. Close unused connections or reduce the remote desktop size before connecting again."
    case .internalFailure: return "The viewer could not complete this operation. Close this connection window and create a new connection."
    case .unsupportedEndpoint: return "This server address uses a transport unavailable in this build. Choose a supported server address."
    case .invalidEndpoint: return "Check the server address and port before connecting."
    case .unsupported: return "This operation is not available in this build or connection."
    case .invalidRequest: return "Check the requested settings before trying this command again."
    case .busy: return "Wait for the current operation to finish, then try again."
    case .notConnected: return "Connect to the desktop before using this command."
    case .inputUnavailable: return "Focus the connected desktop and check its view-only and input settings before trying again."
    case .operationTimeout: return "The server did not complete this request in time. Check the connection before trying the command again."
    case .serverRejected: return "The server rejected this request. Check the requested settings and server capabilities."
    case .operationFailed: return "The request could not be completed. Check the connection before trying the command again."
    }
  }
}
