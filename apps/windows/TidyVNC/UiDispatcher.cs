// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using Microsoft.UI.Dispatching;
using TidyVNC.Native;

namespace TidyVNC;

/// <summary>The app's UI thread for TidyVNC.Native (DECISIONS.md D7).</summary>
internal sealed class UiDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public DispatcherQueue Queue { get; } = queue;
    public bool HasThreadAccess => Queue.HasThreadAccess;
    public bool TryEnqueue(Action action) => Queue.TryEnqueue(() => action());
}
