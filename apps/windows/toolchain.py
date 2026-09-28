"""Locate the MSVC toolchain and produce a build environment for x64 and ARM64.

Shared by deps.py, build.py and the Windows verification scripts so every step
uses the same toolset. Hosts are always x64; ARM64 is cross-compiled with the
MSVC ARM64 build tools component.
"""
import json
import os
from pathlib import Path
import subprocess

VSWHERE = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / \
    "Microsoft Visual Studio/Installer/vswhere.exe"
PREFERRED_TOOLSET = "14.44"
ARCHES = ("x64", "arm64")


def installation():
    """The newest Visual Studio (or Build Tools) with the C++ toolset."""
    output = subprocess.check_output(
        [str(VSWHERE), "-all", "-products", "*", "-latest", "-format", "json",
         "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"], text=True)
    found = json.loads(output)
    if not found:
        raise SystemExit("No Visual Studio installation with the MSVC x64 toolset was found")
    return Path(found[0]["installationPath"])


def toolset(vs=None, arch="x64"):
    """The preferred MSVC toolset when it can build for arch, otherwise the newest that can.

    Visual Studio 2026 installs the 14.44 toolset as an optional component, which can be
    present for x64 alone (as on GitHub's hosted runners); ARM64 then uses the default toolset.
    """
    vs = vs or installation()
    versions = sorted((p for p in (vs / "VC/Tools/MSVC").iterdir() if p.is_dir()),
                      key=lambda p: [int(x) for x in p.name.split(".")])
    capable = [p for p in versions if (p / "bin/Hostx64" / arch / "cl.exe").exists()] or versions
    for candidate in reversed(capable):
        if candidate.name.startswith(PREFERRED_TOOLSET):
            return candidate
    return capable[-1]


def tool(name, vs=None):
    return toolset(vs) / "bin/Hostx64/x64" / name


def has_msvc_arm64(vs=None):
    return (toolset(vs, "arm64") / "bin/Hostx64/arm64/cl.exe").exists()


def environment(arch, vs=None):
    """Return os.environ plus the vcvarsall environment for arch (host x64)."""
    if arch not in ARCHES:
        raise ValueError(arch)
    vs = vs or installation()
    version = toolset(vs, arch).name
    # x64_arm64 needs the MSVC cross tools for cl.exe, but vcvarsall still sets
    # LIB/INCLUDE for ARM64 when only the libraries are present.
    target = "x64" if arch == "x64" else "x64_arm64"
    vcvars = vs / "VC/Auxiliary/Build/vcvarsall.bat"
    command = f'"{vcvars}" {target} -vcvars_ver={version} >nul && set'
    # A string, not a list: cmd.exe /s strips exactly one pair of outer quotes.
    output = subprocess.check_output(f'cmd.exe /d /s /c "{command}"', text=True)
    env = {}
    for line in output.splitlines():
        key, sep, value = line.partition("=")
        if sep and key:
            env[key] = value
    if "LIB" not in env or ("arm64" if arch == "arm64" else "x64") not in env["LIB"].lower():
        raise SystemExit(f"vcvarsall did not provide {arch} libraries")
    return env


def cmake_compilers(arch, vs=None, build=None):
    """CMake cache arguments selecting MSVC for arch (host x64)."""
    if arch == "x64":
        return ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl"]
    if not has_msvc_arm64(vs):
        # Both the ARM64 cross compiler and the ARM64 C runtime libraries come
        # with this component; clang cannot link without the latter either.
        raise SystemExit("ARM64 builds need the Visual Studio component "
                         "'MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools (Latest)' "
                         "(Microsoft.VisualStudio.Component.VC.Tools.ARM64)")
    return ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl",
            "-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=ARM64"]


def describe(vs=None, arch="x64"):
    vs = vs or installation()
    return {"visual_studio": str(vs), "msvc_toolset": toolset(vs, arch).name,
            "msvc_arm64_cross": has_msvc_arm64(vs)}
