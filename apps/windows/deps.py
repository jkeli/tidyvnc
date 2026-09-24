#!/usr/bin/env python3
"""Stage the MSYS2-built C dependency DLLs for the MSVC core.

DECISIONS.md D3 (revised): the vcpkg gnutls port does not support MSVC, and
the vcpkg ARM64 triplet needs MSVC ARM64 build tools, so every C dependency
of the core -- GnuTLS, nettle, hogweed, GMP, zlib, pixman and libjpeg-turbo,
with their DLL closure -- comes from the MSYS2 CLANG64 (x64) or CLANGARM64
(ARM64) environment. vcpkg supplies only GoogleTest for the tests. Both link only the
Universal CRT, so they share a C runtime with MSVC code. This script copies
their headers and DLLs into a prefix CMake can use and generates MSVC import
libraries from the DLL export tables. It records package versions and licence
files in deps.json for the package report.

The prefix layout is:
  <out>/include/{gnutls,nettle,pixman-1,gmp.h,zlib.h,zconf.h,jpeglib.h,...}
  <out>/lib/{gnutls,nettle,hogweed,gmp,zlib,pixman-1,jpeg}.lib
  <out>/bin/*.dll           the complete runtime closure
  <out>/share/licenses/<package>/...
  <out>/deps.json
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolchain  # noqa: E402

ENVIRONMENTS = {"x64": ("clang64", "mingw-w64-clang-x86_64"),
                "arm64": ("clangarm64", "mingw-w64-clang-aarch64")}
# Libraries the core links directly: (import library name, DLL).
LINKED = {"gnutls": "libgnutls-30.dll", "nettle": "libnettle-9.dll",
          "hogweed": "libhogweed-7.dll", "gmp": "libgmp-10.dll", "zlib": "zlib1.dll",
          "pixman-1": "libpixman-1-0.dll", "jpeg": "libjpeg-8.dll"}
HEADERS = ["gnutls", "nettle", "gmp.h", "zlib.h", "zconf.h", "pixman-1",
           "jpeglib.h", "jconfig.h", "jmorecfg.h", "jerror.h"]
# Licence texts some MSYS2 packages do not ship under share/licenses. They are
# the upstream COPYING files of the same release, kept in the repository.
LICENCE_OVERRIDES = Path(__file__).resolve().parent / "ThirdParty"
MACHINE = {"x64": "x64", "arm64": "arm64"}


def dumpbin(*args):
    return subprocess.check_output([str(toolchain.tool("dumpbin.exe")), "/nologo", *map(str, args)],
                                   text=True, errors="replace")


def dependents(dll):
    names = []
    for line in dumpbin("/dependents", dll).splitlines():
        line = line.strip()
        if line.lower().endswith(".dll") and " " not in line:
            names.append(line)
    return names


def exports(dll):
    names, started = [], False
    for line in dumpbin("/exports", dll).splitlines():
        if re.match(r"\s*ordinal\s+hint\s+RVA\s+name", line):
            started = True
            continue
        if started:
            match = re.match(r"\s*\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)", line)
            if match:
                names.append(match.group(1))
            elif line.strip().startswith("Summary"):
                break
    return names


def owner(msys, path):
    relative = "/" + Path(path).relative_to(msys).as_posix()
    output = subprocess.check_output([str(msys / "usr/bin/pacman.exe"), "-Qo", relative], text=True)
    match = re.search(r"is owned by (\S+) (\S+)", output)
    return match.group(1), match.group(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arch", choices=toolchain.ARCHES, default="x64")
    parser.add_argument("--msys-root", type=Path, default=Path(r"C:\msys64"))
    parser.add_argument("--out", type=Path, help="Prefix directory (default build/winui/deps/<arch>)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = (args.out or root / "build/winui/deps" / args.arch).resolve()
    env_dir, package_prefix = ENVIRONMENTS[args.arch]
    prefix = args.msys_root / env_dir
    if not (prefix / "bin" / LINKED["gnutls"]).exists():
        raise SystemExit(f"{prefix} has no GnuTLS; install {package_prefix}-gnutls with pacman")
    if out.exists():
        shutil.rmtree(out)
    for sub in ("include", "lib", "bin", "share/licenses", "def"):
        (out / sub).mkdir(parents=True)

    # DLL closure within the MSYS2 prefix; system DLLs and API sets stay out.
    closure, pending = {}, list(LINKED.values())
    while pending:
        name = pending.pop()
        if name.lower() in closure:
            continue
        path = prefix / "bin" / name
        if not path.exists():
            continue
        closure[name.lower()] = path
        pending.extend(dependents(path))
    packages = {}
    for path in sorted(closure.values()):
        shutil.copy2(path, out / "bin" / path.name)
        package, version = owner(args.msys_root, path)
        packages.setdefault(package, {"version": version, "files": []})["files"].append(path.name)
        if package.startswith("mingw-w64-clang"):
            if re.search(r"(libgcc|libstdc\+\+|libc\+\+|libunwind|winpthread)", path.name, re.I):
                raise SystemExit(f"Unexpected compiler runtime in the closure: {path.name}")

    for header in HEADERS:
        source = prefix / "include" / header
        if source.is_dir():
            shutil.copytree(source, out / "include" / header)
        else:
            shutil.copy2(source, out / "include" / header)

    lib = toolchain.tool("lib.exe")
    for name, dll in LINKED.items():
        definition = out / "def" / f"{name}.def"
        symbols = exports(prefix / "bin" / dll)
        if not symbols:
            raise SystemExit(f"No exports read from {dll}")
        definition.write_text(f"LIBRARY {dll}\nEXPORTS\n" + "".join(f"  {s}\n" for s in symbols))
        subprocess.run([str(lib), "/nologo", f"/def:{definition}", f"/machine:{MACHINE[args.arch]}",
                        f"/out:{out / 'lib' / (name + '.lib')}"], check=True, stdout=subprocess.DEVNULL)

    missing = []
    for package in packages:
        short = package[len(package_prefix) + 1:]
        target = out / "share/licenses" / short
        source = prefix / "share/licenses" / short
        override = LICENCE_OVERRIDES / short
        if source.is_dir():
            shutil.copytree(source, target)
        elif override.is_dir():
            shutil.copytree(override, target)
        else:
            missing.append(short)
        packages[package]["licence_dir"] = f"share/licenses/{short}" if target.exists() else None

    report = {"architecture": args.arch, "msys_environment": env_dir,
              "packages": packages, "linked": LINKED, "missing_licences": missing,
              "toolchain": toolchain.describe()}
    (out / "deps.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Staged {len(closure)} DLLs from {env_dir} into {out}")
    if missing:
        print("Licence text still needed for: " + ", ".join(missing))


if __name__ == "__main__":
    main()
