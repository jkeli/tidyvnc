// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Text;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native;

public enum NativeInvocationAction : uint { Launch = 0, Help = 1, Version = 2 }

/// <summary>One validated command-line assignment (canonical name and value).</summary>
public sealed record NativeInvocationAssignment(uint Category, uint Argument, uint ValueArgument, string Name, string Value);

/// <summary>A parameter of the shared command-line schema.</summary>
public sealed record NativeInvocationOption(uint Category, bool Boolean, bool Available, string Name, string Alias);

/// <summary>A command-line syntax error from the core parser (NativeInvocationFailure in Swift).</summary>
public sealed class NativeInvocationFailure : Exception
{
    public enum Problem : uint
    {
        TooManyArguments = 1, TooLarge = 2, NullByte = 3, UnknownOption = 4, MissingValue = 5, Unavailable = 6,
        ExtraOperand = 7, InvalidText = 8, InvalidValue = 9,
    }

    public Problem Reason { get; }
    /// <summary>One-based argument (excluding the executable), or zero for whole-input limits.</summary>
    public uint Argument { get; }

    public NativeInvocationFailure(Problem reason, uint argument) : base(Describe(reason, argument))
    {
        Reason = reason; Argument = argument;
    }

    private static string Describe(Problem reason, uint argument)
    {
        var message = reason switch
        {
            Problem.TooManyArguments => "Too many command-line arguments.",
            Problem.TooLarge => "Command-line input exceeds its byte limit.",
            Problem.NullByte => "A command-line argument contains a null byte.",
            Problem.UnknownOption => "An unrecognized command-line option was supplied.",
            Problem.MissingValue => "A command-line option requires a value.",
            Problem.Unavailable => "A command-line option is unavailable in this build.",
            Problem.ExtraOperand => "Only one server address, connection file or listen port may be supplied.",
            Problem.InvalidText => "A command-line argument is not valid UTF-8.",
            _ => "A command-line option has an invalid value.",
        };
        return argument == 0 ? message : $"Argument {argument}: {message}";
    }
}

/// <summary>
/// The shared command-line grammar (tidyvnc_invocation_*): parse and validate
/// arguments (excluding the executable), with the action, operand and
/// canonical assignments. No IO, settings or connection.
/// </summary>
public sealed class NativeInvocation
{
    public NativeInvocationAction Action { get; }
    public string? Operand { get; }
    public uint OperandArgument { get; }
    public IReadOnlyList<NativeInvocationAssignment> Assignments { get; }

    private NativeInvocation(NativeInvocationAction action, string? operand, uint operandArgument, IReadOnlyList<NativeInvocationAssignment> assignments)
    {
        Action = action; Operand = operand; OperandArgument = operandArgument; Assignments = assignments;
    }

    /// <summary>The last value given for a parameter, if any (names are canonical).</summary>
    public string? Value(string name) => Assignments.LastOrDefault(a => string.Equals(a.Name, name, StringComparison.OrdinalIgnoreCase))?.Value;

    public static unsafe NativeInvocation Parse(IReadOnlyList<string> arguments)
    {
        var encoded = new byte[arguments.Count][];
        var strict = new UTF8Encoding(false, true);
        for (var i = 0; i < arguments.Count; i++)
        {
            try { encoded[i] = strict.GetBytes(arguments[i]); }
            catch (EncoderFallbackException) { throw new NativeInvocationFailure(NativeInvocationFailure.Problem.InvalidText, (uint)i + 1); }
        }
        var handles = new System.Runtime.InteropServices.GCHandle[encoded.Length];
        var spans = new tidyvnc_bytes[encoded.Length];
        try
        {
            for (var i = 0; i < encoded.Length; i++)
            {
                handles[i] = System.Runtime.InteropServices.GCHandle.Alloc(encoded[i], System.Runtime.InteropServices.GCHandleType.Pinned);
                spans[i] = NativeText.Span((byte*)handles[i].AddrOfPinnedObject(), encoded[i].Length);
            }
            var error = Abi.Init<tidyvnc_error>();
            ulong parsed = 0, validated = 0;
            fixed (tidyvnc_bytes* input = spans)
            {
                Check(NativeMethods.tidyvnc_invocation_parse(input, (uint)spans.Length, &parsed, &error), ref error);
            }
            using var parsedOwner = NativeHandle.Adopt(parsed);
            Check(NativeMethods.tidyvnc_invocation_validate(parsedOwner.Raw, &validated, &error), ref error);
            using var owner = NativeHandle.Adopt(validated);
            var info = Abi.Init<tidyvnc_invocation_info>();
            Abi.Check(NativeMethods.tidyvnc_invocation_get(owner.Raw, &info, &error), &error);
            var operand = info.operand.data == null ? null : Encoding.UTF8.GetString(info.operand.data, checked((int)info.operand.length));
            var assignments = new List<NativeInvocationAssignment>((int)info.count);
            for (var i = 0u; i < info.count; i++)
            {
                var value = Abi.Init<tidyvnc_invocation_assignment>();
                Abi.Check(NativeMethods.tidyvnc_invocation_assignment_at(owner.Raw, i, &value, &error), &error);
                assignments.Add(new NativeInvocationAssignment(value.category, value.argument, value.value_argument,
                    NativeText.Fixed(value.name, 64),
                    value.value.data == null ? "" : Encoding.UTF8.GetString(value.value.data, checked((int)value.value.length))));
            }
            return new NativeInvocation((NativeInvocationAction)info.action, operand, info.operand_argument, assignments);
        }
        finally
        {
            foreach (var handle in handles) if (handle.IsAllocated) handle.Free();
        }
    }

    private static unsafe void Check(uint code, ref tidyvnc_error error)
    {
        if (code == Tidyvnc.TIDYVNC_OK) return;
        if (error.domain == Tidyvnc.TIDYVNC_DOMAIN_INVOCATION)
            throw new NativeInvocationFailure((NativeInvocationFailure.Problem)(error.detail & 0xff), error.detail >> 8);
        throw new NativeError(error);
    }

    /// <summary>The schema in catalogue order.</summary>
    public static unsafe IReadOnlyList<NativeInvocationOption> Options()
    {
        var options = new List<NativeInvocationOption>();
        var error = Abi.Init<tidyvnc_error>();
        for (var i = 0u; ; i++)
        {
            var option = Abi.Init<tidyvnc_invocation_option>();
            if (Abi.Check(NativeMethods.tidyvnc_invocation_option_at(i, &option, &error), &error, NativeStatus.Ok, NativeStatus.NoChange) != NativeStatus.Ok)
                return options;
            options.Add(new NativeInvocationOption(option.category, option.boolean != 0, option.available != 0,
                NativeText.Fixed(option.name, 64), NativeText.Fixed(option.alias, 64)));
        }
    }
}
