// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.

public enum NativeNetworkOption: Sendable, Hashable { case ipv4, ipv6 }

// Session-owned outgoing address-family selection. Both disabled is meaningful
// for Unix sockets; the shared connector rejects it for TCP before starting IO.
// This is not persisted or applied to unrelated sessions or future listeners.
public struct NativeNetworkPolicy: Sendable, Equatable {
  public var ipv4: Bool, ipv6: Bool
  public init(ipv4: Bool = true, ipv6: Bool = true) { self.ipv4 = ipv4; self.ipv6 = ipv6 }
  public static let builtIn = NativeNetworkPolicy()
}
