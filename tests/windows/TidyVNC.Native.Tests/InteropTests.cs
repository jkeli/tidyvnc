// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using TidyVNC.Native.Interop;

namespace TidyVNC.Native.Tests;

/// <summary>
/// Windows.Interop: the generated C# declarations match tidyvnc.h exactly
/// (PLAN.md section 5, TESTING.md "Interop"). Sizes and field offsets come
/// from the C compiler through tidyvnc-abi-layout.exe.
/// </summary>
[TestClass]
public sealed class InteropTests
{
    private static JsonDocument Layout()
    {
        var probe = Path.Combine(AppContext.BaseDirectory, "tidyvnc-abi-layout.exe");
        Assert.IsTrue(File.Exists(probe), "Build the core first (apps/windows/build.py --test)");
        using var process = Process.Start(new ProcessStartInfo(probe) { RedirectStandardOutput = true, UseShellExecute = false })!;
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        Assert.AreEqual(0, process.ExitCode);
        return JsonDocument.Parse(output);
    }

    [TestMethod]
    public void EveryStructMatchesTheCLayout()
    {
        using var layout = Layout();
        var assembly = typeof(tidyvnc_error).Assembly;
        var checkedStructs = 0;
        foreach (var entry in layout.RootElement.EnumerateObject())
        {
            var type = assembly.GetType("TidyVNC.Native.Interop." + entry.Name);
            Assert.IsNotNull(type, $"{entry.Name} has no C# declaration");
            var size = (int)typeof(Unsafe).GetMethod(nameof(Unsafe.SizeOf))!.MakeGenericMethod(type).Invoke(null, null)!;
            Assert.AreEqual(entry.Value.GetProperty("size").GetInt32(), size, $"sizeof({entry.Name})");
            foreach (var field in entry.Value.GetProperty("fields").EnumerateObject())
            {
                Assert.IsNotNull(type.GetField(field.Name, BindingFlags.Public | BindingFlags.Instance), $"{entry.Name}.{field.Name} missing");
                var offset = (int)Marshal.OffsetOf(type, field.Name);
                Assert.AreEqual(field.Value.GetInt32(), offset, $"offsetof({entry.Name}, {field.Name})");
            }
            checkedStructs++;
        }
        Assert.IsTrue(checkedStructs >= 60, $"Only {checkedStructs} structs checked");
    }

    [TestMethod]
    public void EveryDeclaredExportResolvesInTheDll()
    {
        var library = NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, "tidyvnc_viewer.dll"));
        var methods = typeof(NativeMethods).GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(m => m.Name.StartsWith("tidyvnc_", StringComparison.Ordinal)).Select(m => m.Name).Distinct().ToList();
        Assert.IsTrue(methods.Count >= 118);
        foreach (var name in methods)
            Assert.IsTrue(NativeLibrary.TryGetExport(library, name, out _), $"{name} is not exported");
    }

    [TestMethod]
    public void AbiVersionAndWindowsFeaturesAreAdvertised()
    {
        var abi = NativeRuntime.GetAbi();
        Assert.IsTrue(abi.Supports(NativeRuntime.RequiredFeatures), "Required features missing");
        Assert.IsTrue(abi.Supports(Tidyvnc.TIDYVNC_FEATURE_LISTENER));
        Assert.IsTrue(abi.Supports(Tidyvnc.TIDYVNC_FEATURE_FILE_LOGGING));
        Assert.IsTrue(abi.Supports(Tidyvnc.TIDYVNC_FEATURE_NATIVE_ERROR_CATEGORY));
        Assert.IsTrue(abi.SecurityTypes.Count > 0);
    }

    [TestMethod]
    public void ErrorsCarryStatusDomainAndFixedText()
    {
        var failure = Assert.ThrowsExactly<NativeError>(() => NativeEndpoint.Validate("[::1"));
        Assert.AreEqual(NativeStatus.InvalidArgument, failure.Status);
        Assert.AreEqual(Tidyvnc.TIDYVNC_DOMAIN_ENDPOINT, failure.Domain);
        Assert.AreEqual(NativeEndpointIssue.UnmatchedBracket, NativeEndpoint.Issue("[::1"));
        Assert.AreEqual(NativeEndpointIssue.Required, NativeEndpoint.Issue(""));
        Assert.IsNull(NativeEndpoint.Issue("server.example:1"));
        Assert.AreEqual(5901u, NativeEndpoint.ParsePort("5901"));
        Assert.IsNull(NativeEndpoint.ParsePort("+5901"));
        Assert.AreEqual(NativeErrorCategory.Refused, NativeErrorCategories.Classify(10061));
        Assert.AreEqual(NativeErrorCategory.Routing, NativeErrorCategories.Classify(10065));
    }

    [TestMethod]
    public void CatalogsAreReadable()
    {
        var security = NativeSecuritySelection.Choices();
        Assert.IsTrue(security.Count >= 10);
        Assert.IsTrue(security.Any(choice => choice.Name == "VncAuth" && choice.Available));
        Assert.IsTrue(security.Any(choice => choice.Protection == NativeSecurityChoice.ProtectionKind.X509Tls && choice.Available));
        Assert.IsTrue(security.Any(choice => choice.Protection == NativeSecurityChoice.ProtectionKind.RsaAes && choice.Available));
        var denied = new NativeSecuritySelection("");
        Assert.AreEqual(0, denied.Types.Count);
        var schema = NativeEncodingOptions.Schema();
        Assert.IsTrue(schema.Any(entry => entry.Id == NativeEncodingOption.Quality));
        using var options = new NativeEncodingOptions([new NativeEncodingAssignment("QualityLevel", "3")]);
        Assert.AreEqual(new NativeEncodingValue("3", NativeOptionSource.Session), options.Value(NativeEncodingOption.Quality));
        var bad = Assert.ThrowsExactly<NativeError>(() => new NativeEncodingOptions([new NativeEncodingAssignment("QualityLevel", "12")]));
        Assert.AreEqual(NativeEncodingProblem.InvalidValue, bad.EncodingProblem());
    }
}
