#!/usr/bin/env python3
"""Build the native app's C dependencies from pinned source as static libraries.

Every library the macOS core links -- GMP, Nettle/Hogweed, libidn2, GnuTLS,
pixman and libjpeg-turbo -- is built here from an upstream release archive
whose SHA-256 is pinned below, for one architecture and deployment target. The
app then links them statically, so it depends only on libraries macOS itself
provides and never on Homebrew or anything else installed on the build host.

The build environment is isolated: a minimal environment, the Xcode compiler,
pkg-config restricted to this prefix, and only the build tools named in TOOLS
on PATH. GnuTLS uses the macOS Keychain as its system trust store (not a
certificate file on the build host) and omits p11-kit, TPM and certificate
compression; the core uses none of them. Every archive member is checked
against the architecture and deployment target, because the linker only warns
when a static object requires a newer macOS than the app it is linked into.

The prefix layout is:
  <out>/include/...
  <out>/lib/*.a                          static libraries only
  <out>/lib/pkgconfig/*.pc
  <out>/share/licenses/<package>/...     upstream licence texts
  <out>/deps.json                        versions, sources, hashes and toolchain

An existing prefix with the same recipe (this script, target, architecture
and Xcode) is reused; --force rebuilds it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import urllib.request

GNU = "https://ftpmirror.gnu.org"
AUTOTOOLS = ["--disable-dependency-tracking", "--disable-shared", "--enable-static", "--with-pic"]
# Order matters: each package may use those before it.
PACKAGES = [
    {"name": "gmp", "version": "6.3.0", "build": "autotools",
     "url": f"{GNU}/gmp/gmp-6.3.0.tar.xz",
     "sha256": "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
     "licences": ["COPYING", "COPYINGv2", "COPYINGv3", "COPYING.LESSERv3"],
     "args": AUTOTOOLS + ["--disable-cxx"], "check": True},
    {"name": "nettle", "version": "4.0", "build": "autotools",
     "url": f"{GNU}/nettle/nettle-4.0.tar.gz",
     "sha256": "3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094",
     "licences": ["COPYINGv2", "COPYINGv3", "COPYING.LESSERv3"],
     # Fat builds select the Arm crypto extensions at run time.
     "args": AUTOTOOLS + ["--disable-documentation", "--disable-openssl", "--enable-fat"], "check": True},
    {"name": "libidn2", "version": "2.3.8", "build": "autotools",
     "url": f"{GNU}/libidn/libidn2-2.3.8.tar.gz",
     "sha256": "f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a",
     "licences": ["COPYING", "COPYINGv2", "COPYING.LESSERv3", "COPYING.unicode"],
     "args": AUTOTOOLS + ["--disable-doc", "--disable-nls", "--disable-valgrind-tests",
                          "--with-included-libunistring", "--without-libunistring-prefix",
                          "--without-libiconv-prefix"]},
    {"name": "gnutls", "version": "3.8.13", "build": "autotools",
     "url": "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz",
     "sha256": "ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e",
     "licences": ["COPYING", "COPYING.LESSERv2"],
     # No trust store file: on macOS GnuTLS then reads the Keychain. The
     # priority file is GnuTLS's conventional administrator path, not the prefix.
     "args": AUTOTOOLS + ["--disable-doc", "--disable-tools", "--disable-tests", "--disable-cxx",
                          "--disable-nls", "--without-p11-kit", "--without-tpm", "--without-tpm2",
                          "--without-zlib", "--without-brotli", "--without-zstd", "--without-leancrypto",
                          "--with-included-libtasn1", "--with-included-unistring",
                          "--without-libiconv-prefix", "--without-libseccomp-prefix",
                          "--with-default-trust-store-file=no",
                          "--with-system-priority-file=/etc/gnutls/config"]},
    {"name": "pixman", "version": "0.46.4", "build": "meson",
     "url": "https://cairographics.org/releases/pixman-0.46.4.tar.gz",
     "sha256": "d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c",
     "licences": ["COPYING"],
     "args": ["-Dtests=disabled", "-Ddemos=disabled", "-Dgtk=disabled", "-Dlibpng=disabled",
              "-Dopenmp=disabled", "-Dtimers=false", "-Dgnuplot=false"]},
    {"name": "libjpeg-turbo", "version": "3.2.0", "build": "cmake",
     "url": "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz",
     "sha256": "6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e",
     "licences": ["LICENSE.md", "README.ijg"],
     # The libjpeg v8 API matches the MSYS2 libjpeg-8 the Windows core uses.
     "args": ["-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DWITH_JPEG8=ON", "-DWITH_TURBOJPEG=OFF",
              "-DWITH_JAVA=OFF"], "check": True},
]
# Build tools only; nothing from their installations is linked.
TOOLS = ("pkg-config", "meson", "ninja", "cmake", "ctest")


class DepsError(RuntimeError):
    pass


def version(value):
    return tuple(int(x) for x in value.split(".")) + (0,) * (3 - len(value.split(".")))


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(package, sources):
    archive = sources / package["url"].rsplit("/", 1)[1]
    if not archive.exists():
        sources.mkdir(parents=True, exist_ok=True)
        partial = archive.with_name(archive.name + ".part")
        print(f"Downloading {package['url']}", flush=True)
        try:
            with urllib.request.urlopen(package["url"], timeout=120) as response, partial.open("wb") as out:
                shutil.copyfileobj(response, out)
        except OSError as error:
            raise DepsError(f"Could not download {package['url']}: {error}")
        partial.rename(archive)
    actual = digest(archive)
    if actual != package["sha256"]:
        raise DepsError(f"{archive} has SHA-256 {actual}, expected {package['sha256']}; delete it if it is a bad download")
    return archive


def tool_dir(work):
    """A PATH directory holding only the named build tools."""
    bin_dir = work / "tools"
    shutil.rmtree(bin_dir, ignore_errors=True)
    bin_dir.mkdir(parents=True)
    for name in TOOLS:
        found = shutil.which(name)
        if not found:
            raise DepsError(f"{name} is required on PATH (for example: brew install pkgconf meson ninja cmake)")
        (bin_dir / name).symlink_to(Path(found).resolve())
    return bin_dir


def environment(prefix, work, arch, target):
    def xcrun(*args):
        return subprocess.check_output(["/usr/bin/xcrun", *args], text=True).strip()
    flags = f"-arch {arch} -mmacosx-version-min={target} -O2"
    env = {"PATH": f"{tool_dir(work)}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("HOME", "/tmp"),
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "LANG": "C", "LC_ALL": "C",
           "SDKROOT": xcrun("--sdk", "macosx", "--show-sdk-path"), "MACOSX_DEPLOYMENT_TARGET": target,
           "CC": xcrun("-f", "clang"), "CXX": xcrun("-f", "clang++"),
           "AR": xcrun("-f", "ar"), "RANLIB": xcrun("-f", "ranlib"),
           "CFLAGS": flags, "CXXFLAGS": flags, "CPPFLAGS": f"-I{prefix}/include",
           "LDFLAGS": f"-arch {arch} -mmacosx-version-min={target} -L{prefix}/lib",
           "PKG_CONFIG_LIBDIR": f"{prefix}/lib/pkgconfig"}
    if os.environ.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
    return env


def build(package, archive, prefix, work, env, arch, target, jobs, check):
    source = work / f"{package['name']}-{package['version']}"
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    subprocess.run(["/usr/bin/tar", "-xf", archive, "-C", source, "--strip-components=1"], check=True)
    log = work / f"{package['name']}.log"
    print(f"Building {package['name']} {package['version']} (log: {log})", flush=True)
    check = check and package.get("check", False)
    with log.open("w") as stream:
        def run(*command, cwd=source):
            stream.write(f"$ {' '.join(map(str, command))}\n")
            stream.flush()
            result = subprocess.run([str(x) for x in command], cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
            if result.returncode:
                raise DepsError(f"{package['name']}: {command[0]} failed ({result.returncode}); see {log}")
        if package["build"] == "autotools":
            run("./configure", f"--prefix={prefix}", *package["args"])
            run("make", f"-j{jobs}")
            if check:
                run("make", f"-j{jobs}", "check")
            run("make", "install")
        elif package["build"] == "meson":
            run("meson", "setup", "build", f"--prefix={prefix}", "--libdir=lib", "--buildtype=release",
                "--default-library=static", "-Db_staticpic=true", *package["args"])
            run("meson", "install", "-C", "build")
        else:
            tests = "ON" if check else "OFF"
            run("cmake", "-S", ".", "-B", "build", "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
                f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_INSTALL_LIBDIR=lib",
                f"-DCMAKE_OSX_ARCHITECTURES={arch}", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={target}",
                "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", f"-DWITH_TESTS={tests}", f"-DWITH_TOOLS={tests}",
                *package["args"])
            run("cmake", "--build", "build", "--parallel", jobs)
            if check:
                run("ctest", "--test-dir", "build", "--parallel", jobs, "--output-on-failure")
            run("cmake", "--install", "build")
    licences = prefix / "share/licenses" / package["name"]
    licences.mkdir(parents=True)
    for name in package["licences"]:
        shutil.copyfile(source / name, licences / name)
    shutil.rmtree(source)
    return {"version": package["version"], "url": package["url"], "sha256": package["sha256"],
            "licence_dir": str(licences.relative_to(prefix)), "checked": check}


def prune(prefix):
    """Keep only what the core build consumes: headers, static libraries, pkg-config and licences."""
    for sub in ("bin", "share/man", "share/doc", "share/info", "share/aclocal", "lib/cmake"):
        shutil.rmtree(prefix / sub, ignore_errors=True)
    for path in (prefix / "lib").glob("*.la"):
        path.unlink()
    for path in (prefix / "share").iterdir():
        if path.name != "licenses":
            shutil.rmtree(path) if path.is_dir() else path.unlink()


def verify(prefix, arch, target):
    """Only static libraries, each member built for this architecture and no newer than the target."""
    libraries = sorted((prefix / "lib").glob("*.a"))
    for path in prefix.rglob("*"):
        if path.suffix in (".dylib", ".so", ".tbd") or ".framework" in path.name:
            raise DepsError(f"Unexpected shared library in the prefix: {path}")
    if not libraries:
        raise DepsError(f"No static libraries in {prefix / 'lib'}")
    records = {}
    for library in libraries:
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", library], text=True).split()
        if archs != [arch]:
            raise DepsError(f"{library.name} has architectures {archs}, expected {arch}")
        member, command, minimums, members = None, None, {}, 0
        for line in subprocess.check_output(["/usr/bin/otool", "-l", library], text=True).splitlines():
            if line.startswith(str(library) + "("):
                member, command, members = line[len(str(library)) + 1:].rstrip("):"), None, members + 1
                continue
            fields = line.split()
            if fields[:1] == ["cmd"]:
                command = fields[1]
            # LC_BUILD_VERSION's tool entries also have a "version" field.
            elif member and len(fields) == 2 and (command, fields[0]) in (
                    ("LC_BUILD_VERSION", "minos"), ("LC_VERSION_MIN_MACOSX", "version")):
                minimums[member] = fields[1]
        newer = {m: v for m, v in minimums.items() if version(v) > version(target)}
        if newer:
            raise DepsError(f"{library.name} members require a newer macOS than {target}: {newer}")
        if not minimums:
            raise DepsError(f"{library.name}: no member records a minimum macOS version")
        records[library.name] = {"sha256": digest(library), "members": members,
                                 "minimumOS": max(minimums.values(), key=version)}
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="Prefix directory (default build/native-deps/<arch>)")
    parser.add_argument("--sources", type=Path, help="Archive cache (default build/native-deps/sources)")
    parser.add_argument("--work", type=Path, help="Build directory (default build/native-deps/work)")
    parser.add_argument("--deployment-target", default="13.0")
    parser.add_argument("--parallel", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--check", action="store_true", help="Run the GMP, Nettle and libjpeg-turbo test suites")
    parser.add_argument("--force", action="store_true", help="Rebuild even if the prefix matches the recipe")
    args = parser.parse_args()
    arch = platform.machine()
    if arch != "arm64":
        raise SystemExit(f"Native dependencies are built for Apple silicon only, not {arch}")
    if not re.fullmatch(r"\d+\.\d+", args.deployment_target):
        parser.error("--deployment-target must look like 13.0")
    root = Path(__file__).resolve().parents[2]
    base = root / "build/native-deps"
    out = (args.out or base / arch).resolve()
    sources = (args.sources or base / "sources").resolve()
    work = (args.work or base / "work").resolve()
    if out.is_relative_to(work) or work.is_relative_to(out):
        parser.error("--out and --work must be separate directories")

    xcode = subprocess.check_output(["/usr/bin/xcrun", "xcodebuild", "-version"], text=True).split()
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    recipe = hashlib.sha256(Path(__file__).read_bytes() + json.dumps(
        [arch, args.deployment_target, xcode, sdk]).encode()).hexdigest()
    manifest = out / "deps.json"
    if not args.force and manifest.exists():
        previous = json.loads(manifest.read_text())
        if previous.get("recipe") == recipe and (not args.check or previous.get("checked")):
            print(f"Dependencies in {out} are up to date")
            return

    archives = [fetch(package, sources) for package in PACKAGES]
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    work.mkdir(parents=True, exist_ok=True)
    env = environment(out, work, arch, args.deployment_target)
    packages = {}
    for package, archive in zip(PACKAGES, archives):
        packages[package["name"]] = build(package, archive, out, work, env, arch, args.deployment_target,
                                          args.parallel, args.check)
    prune(out)
    libraries = verify(out, arch, args.deployment_target)
    tools = {name: subprocess.check_output([name, "--version"], env=env, text=True).splitlines()[0]
             for name in TOOLS}
    report = {"schemaVersion": 1, "recipe": recipe, "architecture": arch,
              "deploymentTarget": args.deployment_target, "checked": args.check,
              "xcode": " ".join(xcode), "sdk": sdk, "tools": tools,
              "packages": packages, "libraries": libraries}
    manifest.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Built {len(libraries)} static libraries for {arch} macOS {args.deployment_target} into {out}")


if __name__ == "__main__":
    try:
        main()
    except DepsError as error:
        sys.exit(f"deps.py: {error}")
