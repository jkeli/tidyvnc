"""Locate the MSVC toolchain and produce a build environment for x64 and ARM64.

Shared by deps.py, build.py and the Windows verification scripts so every step
uses the same toolset. Hosts are always x64; ARM64 cross-builds use clang-cl
with the MSVC and Windows SDK ARM64 libraries when the MSVC ARM64 cross
compiler is not installed.
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


def toolset(vs=None):
    vs = vs or installation()
    versions = sorted((p for p in (vs / "VC/Tools/MSVC").iterdir() if p.is_dir()),
                      key=lambda p: [int(x) for x in p.name.split(".")])
    for candidate in reversed(versions):
        if candidate.name.startswith(PREFERRED_TOOLSET):
            return candidate
    return versions[-1]


def tool(name, vs=None):
    return toolset(vs) / "bin/Hostx64/x64" / name


def has_msvc_arm64(vs=None):
    return (toolset(vs) / "bin/Hostx64/arm64/cl.exe").exists()


def clang_cl(vs=None):
    vs = vs or installation()
    path = vs / "VC/Tools/Llvm/x64/bin/clang-cl.exe"
    return path if path.exists() else None


def environment(arch, vs=None):
    """Return os.environ plus the vcvarsall environment for arch (host x64)."""
    if arch not in ARCHES:
        raise ValueError(arch)
    vs = vs or installation()
    version = toolset(vs).name
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


def cmake_compilers(arch, vs=None):
    """CMake cache arguments selecting the compiler for arch."""
    if arch == "x64":
        return ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl"]
    if has_msvc_arm64(vs):
        return ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl",
                "-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=ARM64"]
    clang = clang_cl(vs)
    if not clang:
        raise SystemExit("ARM64 needs the MSVC ARM64 build tools or clang-cl")
    lld = clang.parent / "lld-link.exe"
    target = "--target=aarch64-pc-windows-msvc"
    return [f"-DCMAKE_C_COMPILER={clang.as_posix()}", f"-DCMAKE_CXX_COMPILER={clang.as_posix()}",
            f"-DCMAKE_LINKER={lld.as_posix()}", f"-DCMAKE_C_FLAGS_INIT={target}",
            f"-DCMAKE_CXX_FLAGS_INIT={target}", "-DCMAKE_SYSTEM_NAME=Windows",
            "-DCMAKE_SYSTEM_PROCESSOR=ARM64"]


def describe(vs=None):
    vs = vs or installation()
    return {"visual_studio": str(vs), "msvc_toolset": toolset(vs).name,
            "msvc_arm64_cross": has_msvc_arm64(vs),
            "clang_cl": str(clang_cl(vs)) if clang_cl(vs) else None}
