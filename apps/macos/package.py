#!/usr/bin/env python3
"""Assemble a relocatable native macOS app and optional disk image.

Works on a private copy, never edits the Xcode bundle or dependency installation.
The selected deployment floor is enforced for every executable and dylib.
Third-party libraries are linked statically from the apps/macos/deps.py prefix:
the package carries their licence texts and rejects any other dynamic library.
Signing and local packaging do not establish notarization or installed-app acceptance.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile


class PackageError(RuntimeError):
    pass


MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
          b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
LOADS = {0xC, 0x18 | 0x80000000, 0x1F | 0x80000000, 0x20, 0x23 | 0x80000000}


def version(value):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise PackageError(f"Invalid macOS version: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def system_path(value):
    # Normalize before classification so /usr/lib/../../tmp is not exempted.
    path = Path(os.path.normpath(value))
    return path.is_relative_to("/usr/lib") or path.is_relative_to("/System/Library")


def macho(path):
    """Read only the single-architecture 64-bit Mach-O format our build supports."""
    data = path.read_bytes()
    if data[:4] != b"\xcf\xfa\xed\xfe" or len(data) < 32:
        raise PackageError(f"Expected thin little-endian 64-bit Mach-O: {path}")
    cpu, _, kind, count, size = struct.unpack_from("<IIIII", data, 4)
    arch = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(cpu)
    if not arch or kind not in (2, 6, 8) or size > len(data) - 32:
        raise PackageError(f"Unsupported Mach-O header: {path}")
    result = {"architecture": arch, "kind": kind, "loads": [], "rpaths": [], "id": None, "minimumOS": None}
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise PackageError(f"Truncated load command: {path}")
        cmd, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > 32 + size:
            raise PackageError(f"Invalid load command: {path}")
        if cmd in LOADS | {0xD, 0x8000001C}:
            if length < 12:
                raise PackageError(f"Truncated string command: {path}")
            start = struct.unpack_from("<I", data, offset + 8)[0]
            if not 12 <= start < length or b"\0" not in data[offset + start:offset + length]:
                raise PackageError(f"Invalid command string: {path}")
            value = data[offset + start:offset + length].split(b"\0", 1)[0].decode("utf-8")
            if cmd == 0xD:
                result["id"] = value
            else:
                result["rpaths" if cmd == 0x8000001C else "loads"].append(value)
        elif cmd in (0x32, 0x24):
            if length < (24 if cmd == 0x32 else 16):
                raise PackageError(f"Truncated version command: {path}")
            if cmd == 0x32 and struct.unpack_from("<I", data, offset + 8)[0] != 1:
                raise PackageError(f"Non-macOS Mach-O platform: {path}")
            number = struct.unpack_from("<I", data, offset + (12 if cmd == 0x32 else 8))[0]
            result["minimumOS"] = f"{number >> 16}.{(number >> 8) & 255}.{number & 255}"
        offset += length
    if offset != 32 + size or result["minimumOS"] is None:
        raise PackageError(f"Missing or inconsistent Mach-O metadata: {path}")
    return result


def binaries(app):
    result = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise PackageError(f"Bundle symlink escapes app: {path}")
            continue
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MAGICS:
                    result.append(path)
    return result


def expand(value, loader, executable):
    for prefix, base in (("@loader_path/", loader.parent), ("@executable_path/", executable.parent)):
        if value.startswith(prefix):
            return base / value[len(prefix):]
    return Path(value) if value.startswith("/") else None


def resolve_load(value, loader, executable, rpaths):
    if system_path(value):
        return value  # OS libraries may exist only in the dyld shared cache.
    candidates = []
    if value.startswith("@rpath/"):
        for rpath in rpaths:
            base = expand(rpath, loader, executable)
            if base is not None:
                candidates.append(base / value[len("@rpath/"):])
    else:
        path = expand(value, loader, executable)
        if path is not None:
            candidates.append(path)
    found = {p.resolve() for p in candidates if p.is_file()}
    if len(found) != 1:
        raise PackageError(f"Unresolved or ambiguous dependency {value!r} in {loader}")
    return found.pop()


def check_binary(path, info, architecture, minimum):
    if info["architecture"] != architecture:
        raise PackageError(f"Architecture mismatch in {path}: {info['architecture']} != {architecture}")
    if version(info["minimumOS"]) > version(minimum):
        raise PackageError(f"{path} requires macOS {info['minimumOS']}, above package minimum {minimum}")
    if "fltk" in path.name.lower() or any("fltk" in value.lower() for value in info["loads"]):
        raise PackageError(f"FLTK dependency in native package: {path}")


def dependency_graph(app, executable, minimum):
    initial = binaries(app)
    architecture = macho(executable)["architecture"]
    root_rpaths = [str(expand(p, executable, executable)) for p in macho(executable)["rpaths"]
                   if expand(p, executable, executable) is not None]
    pending = [(p, root_rpaths) for p in initial]
    nodes, names = {}, {}
    while pending:
        source, inherited_rpaths = pending.pop()
        source = source.resolve()
        info = macho(source)
        check_binary(source, info, architecture, minimum)
        if source.is_relative_to(app):
            target = source.relative_to(app)
        else:
            if info["kind"] != 6 or ".framework" in str(source):
                raise PackageError(f"Only standalone third-party dylibs are supported: {source}")
            target = Path("Contents/Frameworks") / source.name
        if target in names and names[target] != source:
            raise PackageError(f"Dependency destination collision: {source} and {names[target]}")
        names[target] = source
        edges = {}
        rpaths = [str(expand(p, source, executable)) for p in info["rpaths"]
                  if expand(p, source, executable) is not None] + inherited_rpaths
        for value in info["loads"]:
            resolved = resolve_load(value, source, executable, rpaths)
            edges[value] = resolved
        if source in nodes:
            if edges != nodes[source]["edges"]:
                raise PackageError(f"Context-dependent runpath resolution: {source}")
            continue
        nodes[source] = {"target": target, "info": info, "edges": edges}
        pending.extend((p, rpaths) for p in edges.values() if isinstance(p, Path))
    return nodes, architecture


def run(*args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(source, destination):
    # Darwin's exclusive rename also protects an empty directory created by
    # another packager between preflight and publication. os.rename can replace it.
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x4) != 0:  # RENAME_EXCL
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def static_dependencies(prefix, architecture, minimum):
    """The deps.py manifest, checked against the libraries still in its prefix."""
    try:
        manifest = json.loads((prefix / "deps.json").read_text())
    except (OSError, ValueError) as error:
        raise PackageError(f"No dependency manifest in {prefix}; run apps/macos/deps.py: {error}")
    if manifest.get("architecture") != architecture:
        raise PackageError(f"Dependencies are for {manifest.get('architecture')}, the app for {architecture}")
    if version(manifest["deploymentTarget"]) > version(minimum):
        raise PackageError(f"Dependencies target macOS {manifest['deploymentTarget']}, above package minimum {minimum}")
    for name, record in manifest["libraries"].items():
        path = prefix / "lib" / name
        if not path.is_file() or digest(path) != record["sha256"]:
            raise PackageError(f"{path} differs from {prefix / 'deps.json'}; rebuild with apps/macos/deps.py")
    return manifest


def copy_notices(prefix, manifest, target):
    """Each package's licence texts, and a README naming the source it was built from."""
    records = []
    lines = ["TidyVNC links the libraries below statically. Each directory holds the",
             "licence texts from the release archive the library was built from.", ""]
    for name, package in manifest["packages"].items():
        source = (prefix / package["licence_dir"]).resolve()
        files = sorted(p for p in source.iterdir() if p.is_file()) if source.is_dir() else []
        if not source.is_relative_to(prefix.resolve()) or not files:
            raise PackageError(f"No licence text for {name} in {source}")
        (target / name).mkdir(parents=True)
        for path in files:
            shutil.copyfile(path, target / name / path.name)
        records.append({"name": name, "version": package["version"], "linkage": "static",
                        "source": package["url"], "sourceSHA256": package["sha256"],
                        "notices": {p.name: digest(p) for p in files}})
        lines += [f"{name} {package['version']}", f"  Source:   {package['url']}",
                  f"  SHA-256:  {package['sha256']}", f"  Licences: {name}/", ""]
    (target / "README.txt").write_text("\n".join(lines))
    return records


def audit(app, minimum, architecture):
    """Require closed in-bundle links; never use host fallback to prove closure."""
    app = app.resolve()
    if (app / "Contents/Frameworks").exists():
        raise PackageError("Contents/Frameworks in the package; third-party libraries are linked statically")
    executable = app / "Contents/MacOS/vncviewer"
    records = []
    for path in binaries(app):
        info = macho(path)
        check_binary(path, info, architecture, minimum)
        if info["rpaths"]:
            raise PackageError(f"Unexpected runpath in final package: {path}")
        for value in info["loads"]:
            if system_path(value):
                continue
            if not value.startswith("@loader_path/"):
                raise PackageError(f"Non-relocatable dependency {value!r} in {path}")
            resolved = expand(value, path, executable).resolve()
            if not resolved.is_relative_to(app) or not resolved.is_file():
                raise PackageError(f"Dependency escapes or is missing: {value!r} in {path}")
            macho(resolved)
        records.append({"path": str(path.relative_to(app)), "sha256": digest(path),
                        "minimumOS": info["minimumOS"], "dependencies": info["loads"]})
    return records


def package(args):
    app = args.app.resolve()
    output = args.output.parent.resolve() / args.output.name
    if output.exists() or output.is_symlink():
        raise PackageError(f"Output already exists; choose a fresh directory: {output}")
    if output.is_relative_to(app) or app.is_relative_to(output):
        raise PackageError("Package output must be separate from the input app")
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if plist.get("CFBundleIdentifier") != "io.github.jkeli.tidyvnc" or plist.get("CFBundleExecutable") != "vncviewer":
        raise PackageError("Input is not the expected TidyVNC application")
    original_minimum = plist["LSMinimumSystemVersion"]
    minimum = args.minimum_os or original_minimum
    if version(minimum) < version(original_minimum):
        raise PackageError("Package minimum cannot be below the app's declared minimum")
    nodes, architecture = dependency_graph(app, app / "Contents/MacOS/vncviewer", minimum)
    dynamic = sorted(str(source) for source in nodes if not source.is_relative_to(app))
    if dynamic:
        raise PackageError("Third-party libraries must be linked statically (apps/macos/deps.py); "
                           f"the app loads {', '.join(dynamic)}")
    deps = args.deps.resolve()
    dependencies = static_dependencies(deps, architecture, minimum)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tidyvnc-package-", dir=output.parent) as tmp:
        work = Path(tmp)
        staged = work / "TidyVNC.app"
        run("/usr/bin/ditto", app, staged)
        manifest = {"schemaVersion": 1, "version": plist["CFBundleShortVersionString"],
                    "architecture": architecture, "buildMinimumOS": original_minimum,
                    "packageMinimumOS": minimum, "signingIdentity": args.sign_identity,
                    "notarized": False, "dependencies": copy_notices(
                        deps, dependencies, staged / "Contents/Resources/ThirdParty")}
        for source, node in nodes.items():
            target = staged / node["target"]
            target.chmod(target.stat().st_mode | 0o200)
            command = ["/usr/bin/install_name_tool"]
            for old, dependency in node["edges"].items():
                if isinstance(dependency, Path):
                    new = "@loader_path/" + os.path.relpath(nodes[dependency]["target"], node["target"].parent)
                    command += ["-change", old, new]
            for rpath in set(node["info"]["rpaths"]):
                command += ["-delete_rpath", rpath]
            if node["info"]["id"]:
                command += ["-id", "@rpath/" + target.name]
            if len(command) > 1:
                run(*command, target)
        plist["LSMinimumSystemVersion"] = minimum
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        (staged / "Contents/Resources/NativePackage.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Nested code first; no --deep signing or entitlement inheritance.
        signing = ["/usr/bin/codesign", "--force", "--sign", args.sign_identity]
        signing += ["--timestamp=none"] if args.sign_identity == "-" else ["--options", "runtime", "--timestamp"]
        for path in binaries(staged):
            if path != staged / "Contents/MacOS/vncviewer":
                run(*signing, path)
        run(*signing, "--identifier", plist["CFBundleIdentifier"], staged)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged)
        records = audit(staged, minimum, architecture)
        # Relocation is verified by loading from a path with spaces, using an
        # isolated home and no DYLD_* environment overrides or connection input.
        relocated = work / "relocation check/TidyVNC.app"
        relocated.parent.mkdir()
        run("/usr/bin/ditto", staged, relocated)
        home = work / "isolated-home"
        home.mkdir()
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
               "XDG_CONFIG_HOME": str(home / "config"), "XDG_STATE_HOME": str(home / "state")}
        launch = subprocess.run([str(relocated / "Contents/MacOS/vncviewer"), "--help"],
                                env=env, capture_output=True, text=True, timeout=30)
        if launch.returncode != 1 or "AlertOnFatalError" not in launch.stdout + launch.stderr:
            raise PackageError(f"Relocated executable help failed ({launch.returncode}): {launch.stderr}")
        shutil.rmtree(relocated.parent)
        shutil.rmtree(home)
        report = dict(manifest, binaries=records, relocatedHelp="passed", strictSignature="passed")
        if args.dmg:
            image_root = work / "image"
            image_root.mkdir()
            run("/usr/bin/ditto", staged, image_root / staged.name)
            (image_root / "Applications").symlink_to("/Applications")
            for name in ("README.rst", "LICENCE.TXT"):
                shutil.copyfile(staged / "Contents/Resources" / name, image_root / name)
            image = work / f"TidyVNC-{plist['CFBundleShortVersionString']}-{architecture}.dmg"
            run("/usr/bin/hdiutil", "create", "-fs", "HFS+", "-format", "UDZO", "-volname", "TidyVNC", "-srcfolder", image_root, image)
            run("/usr/bin/hdiutil", "verify", image)
            report["diskImage"] = {"path": image.name, "sha256": digest(image), "verification": "passed"}
            shutil.rmtree(image_root)
        (work / "package-report.json").write_text(json.dumps(report, indent=2) + "\n")
        # Publish only a complete verified result. Existing artifacts are not replaced.
        if output.exists() or output.is_symlink():
            raise PackageError(f"Output appeared during packaging: {output}")
        publish(work, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New output directory; never overwritten")
    parser.add_argument("--minimum-os", help="Explicit package floor, at least the app and every dependency minimum")
    parser.add_argument("--sign-identity", default="-", help="Code-signing identity; default ad hoc")
    parser.add_argument("--deps", type=Path, required=True, help="Static dependency prefix from apps/macos/deps.py")
    parser.add_argument("--dmg", action="store_true")
    args = parser.parse_args()
    try:
        print(f"Verified native package: {package(args)}")
    except (PackageError, OSError, ValueError, subprocess.SubprocessError) as error:
        detail = (error.stderr or "") if isinstance(error, subprocess.CalledProcessError) else ""
        parser.exit(1, f"Native packaging failed: {error}\n{detail}")


if __name__ == "__main__":
    main()
