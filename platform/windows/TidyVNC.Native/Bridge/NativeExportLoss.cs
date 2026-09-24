// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

/// <summary>What a compatibility connection file cannot carry (tidyvnc_export_losses).</summary>
[Flags]
public enum NativeExportLoss : uint
{
    None = 0,
    FailureAlerts = 1, RemoteResize = 2, NetworkFamilies = 4, PointerTiming = 8, ClipboardLimit = 16,
    WindowPlacement = 32, DisplayIdentity = 64, IgnoredInput = 128, SshGateway = 256,
}

public sealed class NativeExportRefused(string message) : Exception(message);

public static unsafe class NativeExportLosses
{
    /// <summary>The losses an export must show for review; a custom TLS priority refuses the export.</summary>
    public static NativeExportLoss For(bool selectedDisplays, bool ignoredInput, bool sshGateway, string tlsPriority)
    {
        var priority = Encoding.UTF8.GetBytes(tlsPriority);
        var request = Abi.Init<tidyvnc_export_request>();
        request.selected_displays = selectedDisplays ? 1u : 0u; request.ignored_input = ignoredInput ? 1u : 0u;
        request.ssh_gateway = sshGateway ? 1u : 0u;
        var error = Abi.Init<tidyvnc_error>();
        uint losses = 0, status;
        fixed (byte* p = priority)
        {
            request.tls_priority = NativeText.Span(p, priority.Length);
            status = NativeMethods.tidyvnc_export_losses(&request, &losses, &error);
        }
        if (status != Tidyvnc.TIDYVNC_OK)
        {
            if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_EXPORT && error.detail == Tidyvnc.TIDYVNC_EXPORT_SECURITY_POLICY)
                throw new NativeExportRefused("This file format cannot preserve the custom TLS priority policy. Use a native profile to retain it.");
            throw new NativeError(error);
        }
        return (NativeExportLoss)losses;
    }

    /// <summary>The canonical parameters each loss covers, from the core catalog.</summary>
    public static IReadOnlyDictionary<NativeExportLoss, string[]> Parameters()
    {
        var result = new Dictionary<NativeExportLoss, string[]>();
        var error = Abi.Init<tidyvnc_error>();
        for (var i = 0u; ; i++)
        {
            var info = Abi.Init<tidyvnc_export_loss_info>();
            if (Abi.Check(NativeMethods.tidyvnc_export_loss_at(i, &info, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) != NativeStatus.Ok)
                return result;
            result[(NativeExportLoss)info.loss] = NativeText.Fixed(info.parameters, 96).Split(',', StringSplitOptions.RemoveEmptyEntries);
        }
    }
}
