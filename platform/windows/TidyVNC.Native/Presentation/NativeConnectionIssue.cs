// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
namespace TidyVNC.Native;

/// <summary>
/// A connection or command problem for presentation (NativeConnectionIssue.swift).
/// Only structured codes select the text: remote error strings, endpoints,
/// paths and credential material never become part of this value. Winsock
/// codes are classified by the core (tidyvnc_native_error_category) into the
/// categories macOS derives from errno.
/// </summary>
public enum NativeConnectionIssue
{
    Resolution, ResolutionTimeout, Refused, Routing, NetworkPolicy, ConnectionTimeout,
    Connection, Transport, PeerClosed, AuthenticationRejected, PromptTimeout,
    ProtocolFailure, Resource, InternalFailure, UnsupportedEndpoint, InvalidEndpoint,
    Unsupported, InvalidRequest, Busy, NotConnected, InputUnavailable, OperationTimeout, ServerRejected, OperationFailed,
}

public static class NativeConnectionIssues
{
    /// <summary>The issue a terminal snapshot reports; null when the session is not closed/failed or ended by request.</summary>
    public static NativeConnectionIssue? From(NativeSnapshot snapshot) => From(snapshot, NativeErrorCategories.Classify);

    internal static NativeConnectionIssue? From(NativeSnapshot snapshot, Func<int, NativeErrorCategory> classify)
    {
        if (snapshot.State is not (NativeSessionState.Closed or NativeSessionState.Failed)) return null;
        return snapshot.EndReason switch
        {
            NativeEndReason.None or NativeEndReason.Cancelled => null,
            NativeEndReason.Resolution => NativeConnectionIssue.Resolution,
            NativeEndReason.ResolutionTimeout => NativeConnectionIssue.ResolutionTimeout,
            NativeEndReason.ConnectionTimeout => NativeConnectionIssue.ConnectionTimeout,
            NativeEndReason.Connection or NativeEndReason.Transport => classify(snapshot.NativeCode) switch
            {
                NativeErrorCategory.NetworkPolicy => NativeConnectionIssue.NetworkPolicy,
                NativeErrorCategory.Refused => NativeConnectionIssue.Refused,
                NativeErrorCategory.Routing => NativeConnectionIssue.Routing,
                NativeErrorCategory.TimedOut => NativeConnectionIssue.ConnectionTimeout,
                _ => snapshot.EndReason == NativeEndReason.Transport ? NativeConnectionIssue.Transport : NativeConnectionIssue.Connection,
            },
            NativeEndReason.PeerClosed => NativeConnectionIssue.PeerClosed,
            NativeEndReason.AuthenticationRejected => NativeConnectionIssue.AuthenticationRejected,
            NativeEndReason.PromptTimeout => NativeConnectionIssue.PromptTimeout,
            NativeEndReason.ProtocolFailure => NativeConnectionIssue.ProtocolFailure,
            NativeEndReason.Resource or NativeEndReason.EventOverflow => NativeConnectionIssue.Resource,
            NativeEndReason.UnsupportedEndpoint => NativeConnectionIssue.UnsupportedEndpoint,
            NativeEndReason.InvalidEndpoint => NativeConnectionIssue.InvalidEndpoint,
            _ => NativeConnectionIssue.InternalFailure,
        };
    }

    /// <summary>The issue an operation failure reports; null for cancellation and superseded work.</summary>
    public static NativeConnectionIssue? From(Exception error)
    {
        switch (error)
        {
            case OperationCanceledException:
                return null;
            case NativeCommandFailure failure:
                if (failure.Result == NativeCommandFailure.ResultKind.Cancelled) return null;
                if (From(failure.Snapshot) is { } terminal) return terminal;
                return failure.Reason switch
                {
                    NativeCommandFailure.FailureReason.TimedOut => NativeConnectionIssue.OperationTimeout,
                    NativeCommandFailure.FailureReason.ServerRejected => NativeConnectionIssue.ServerRejected,
                    _ => NativeConnectionIssue.OperationFailed,
                };
            case NativeError native:
                return native.Status switch
                {
                    NativeStatus.Cancelled or NativeStatus.Closing or NativeStatus.Stale or NativeStatus.NotPending => null,
                    NativeStatus.Unsupported => NativeConnectionIssue.Unsupported,
                    NativeStatus.InvalidArgument => NativeConnectionIssue.InvalidRequest,
                    NativeStatus.Busy or NativeStatus.QueueFull => NativeConnectionIssue.Busy,
                    NativeStatus.NotConnected => NativeConnectionIssue.NotConnected,
                    NativeStatus.ViewOnly or NativeStatus.Unfocused or NativeStatus.Disabled => NativeConnectionIssue.InputUnavailable,
                    NativeStatus.ResourceLimit or NativeStatus.OutOfMemory => NativeConnectionIssue.Resource,
                    _ => NativeConnectionIssue.InternalFailure,
                };
            default:
                return NativeConnectionIssue.InternalFailure;
        }
    }

    /// <summary>Connection failures a Retry may repeat (when the session permits reconnecting).</summary>
    public static bool PermitsReconnect(this NativeConnectionIssue issue) => issue is
        NativeConnectionIssue.Resolution or NativeConnectionIssue.ResolutionTimeout or NativeConnectionIssue.Refused or
        NativeConnectionIssue.Routing or NativeConnectionIssue.NetworkPolicy or NativeConnectionIssue.ConnectionTimeout or
        NativeConnectionIssue.Connection or NativeConnectionIssue.Transport or NativeConnectionIssue.PeerClosed or
        NativeConnectionIssue.AuthenticationRejected or NativeConnectionIssue.PromptTimeout or NativeConnectionIssue.ProtocolFailure;

    public static NativeText Title(this NativeConnectionIssue issue) => new(issue switch
    {
        NativeConnectionIssue.Resolution or NativeConnectionIssue.ResolutionTimeout => "connection.issue.resolution.title",
        NativeConnectionIssue.Unsupported => "connection.issue.unsupportedEndpoint.title",
        _ => $"connection.issue.{Name(issue)}.title",
    });

    public static NativeText Message(this NativeConnectionIssue issue) => new($"connection.issue.{Name(issue)}.message");

    /// <summary>The macOS case name, which is also the catalog key segment.</summary>
    private static string Name(NativeConnectionIssue issue)
    {
        var name = issue.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }
}
