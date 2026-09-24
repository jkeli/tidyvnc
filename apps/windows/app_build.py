"""The `app` stage of apps/windows/build.py (plans/native-ui-winui PACKAGING.md
section 2, TODO W3.7).

Publishes apps/windows/TidyVNC (the WinUI app), apps/windows/TidyVNC.Cli
(vncviewer.exe) and apps/windows/TidyVNC.SshAskpass (tidyvnc-ssh-askpass.exe,
started by ssh.exe for SSH gateways) self-contained for one architecture into
one directory, next
to the core DLLs from the `core` stage, and runs the .NET suites for x64 when
--test is given. The payload curation, dependency audit and MSI are the
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
    configuration = "Release" if args.configuration != "Debug" else "Debug"
    native = Path(core) / "bin"
    output = (ROOT / "build/winui" / f"app-{args.arch}-{configuration.lower()}").resolve()
    stamp = output / "tidyvnc-app.json"
    expected = {"arch": args.arch, "configuration": configuration, "core": str(Path(core).resolve())}
    if output.exists():
        if not (stamp.exists() and json.loads(stamp.read_text()) == expected):
            raise SystemExit(f"{output} exists and was not created by app_build.py for {expected}")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    stamp.write_text(json.dumps(expected))
    for project in PROJECTS:
        run(["dotnet", "publish", ROOT / project, "-c", configuration, f"-p:Platform={platform}",
             f"-p:TidyVncNativeBin={native}", "-o", output, "-nologo"])
    for name in ("TidyVNC.exe", "vncviewer.exe", "tidyvnc-ssh-askpass.exe", "tidyvnc_viewer.dll", "tidyvnc_windows.dll"):
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
