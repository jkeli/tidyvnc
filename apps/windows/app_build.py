"""The `app` stage of apps/windows/build.py (plans/native-ui-winui PACKAGING.md
section 2, TODO W3.7).

Publishes apps/windows/TidyVNC (the WinUI app), apps/windows/TidyVNC.Cli
(vncviewer.exe) and apps/windows/TidyVNC.SshAskpass (tidyvnc-ssh-askpass.exe,
started by ssh.exe for SSH gateways) self-contained for one architecture into
one directory, next
to the core DLLs from the `core` stage, and runs the .NET suites for x64 when
--test is given. --measurement publishes a Release build that honours
TIDYVNC_STATE_ROOT, for startup and workload timing, into its own directory
(app-<arch>-measurement, or app-<arch>-measurement-trimmed/-aot when --runtime
trims or AOT-compiles the WinUI app; a trimmed build holds the app alone); the
package stage refuses it. The payload curation, dependency audit and MSI are the
`package` stage (W7).
"""
from pathlib import Path
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROJECTS = ("apps/windows/TidyVNC/TidyVNC.csproj", "apps/windows/TidyVNC.Cli/TidyVNC.Cli.csproj",
            "apps/windows/TidyVNC.SshAskpass/TidyVNC.SshAskpass.csproj")
PLATFORMS = {"x64": "x64", "arm64": "ARM64"}


def run(command, cwd=ROOT):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True, cwd=cwd)


def publish(args, core):
    """Returns the published app directory."""
    platform = PLATFORMS[args.arch]
    measurement, runtime = getattr(args, "measurement", False), getattr(args, "runtime", "jit")
    configuration = "Release" if args.configuration != "Debug" or measurement else "Debug"
    native = Path(core) / "bin"
    name = (f"app-{args.arch}-measurement{'' if runtime == 'jit' else '-' + runtime}" if measurement
            else f"app-{args.arch}-{configuration.lower()}")
    output = (ROOT / "build/winui" / name).resolve()
    stamp = output / "tidyvnc-app.json"
    expected = {"arch": args.arch, "configuration": configuration, "core": str(Path(core).resolve())}
    if measurement:
        expected.update(measurement=True, runtime=runtime)
    if output.exists():
        if not (stamp.exists() and json.loads(stamp.read_text()) == expected):
            raise SystemExit(f"{output} exists and was not created by app_build.py for {expected}")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    stamp.write_text(json.dumps(expected))
    # Trimming rewrites the framework assemblies the untrimmed launcher and askpass helper share, so a
    # trimmed measurement build holds the WinUI app alone (time it with windows-viewer-workloads.py --direct).
    projects = PROJECTS[:1] if runtime == "trimmed" else PROJECTS
    for project in projects:
        extra = ["-p:TidyVncMeasurement=true"] if measurement else []
        if project == PROJECTS[0]:
            # Trimming reports IL2104 for Microsoft.Windows.SDK.NET and WinRT.Runtime (recorded under D1);
            # a measurement build keeps them as warnings.
            extra += {"jit": [], "trimmed": ["-p:PublishTrimmed=true", "-p:WarningsNotAsErrors=IL2104"],
                      "aot": ["-p:PublishAot=true"]}[runtime]
        run(["dotnet", "publish", ROOT / project, "-c", configuration, f"-p:Platform={platform}",
             f"-p:TidyVncNativeBin={native}", "-o", output, "-nologo", *extra])
    expected_files = ("TidyVNC.exe", "tidyvnc_viewer.dll", "tidyvnc_windows.dll") + (
        () if runtime == "trimmed" else ("vncviewer.exe", "tidyvnc-ssh-askpass.exe"))
    for name in expected_files:
        if not (output / name).exists():
            raise SystemExit(f"Publishing did not produce {name}")
    if getattr(args, "test", False):
        if args.arch != "x64":
            print("ARM64 .NET tests run on ARM64 hardware.", flush=True)
        else:
            run(["dotnet", "test", "--project", ROOT / "tests/windows/TidyVNC.Native.Tests/TidyVNC.Native.Tests.csproj", "-c", configuration,
                 f"-p:Platform={platform}", f"-p:TidyVncNativeBin={native}"])
            # UI automation takes over the desktop; it runs only with TIDYVNC_UI_TESTS=1.
            run(["dotnet", "test", "--project", ROOT / "tests/windows/TidyVNC.UITests/TidyVNC.UITests.csproj", "-c", configuration,
                 f"-p:Platform={platform}"])
    return output
