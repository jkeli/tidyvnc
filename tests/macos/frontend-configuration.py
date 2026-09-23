#!/usr/bin/env python3
"""Check real CMake failure paths after building a SwiftUI core with full Xcode.

Uses disposable configure directories; does not modify the supplied core or app.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    args = parser.parse_args()
    core = args.core.resolve()
    cache = {}
    for line in (core / "CMakeCache.txt").read_text().splitlines():
        if "=" in line and ":" in line.split("=", 1)[0]:
            key, value = line.split("=", 1)
            cache[key.split(":", 1)[0]] = value
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tidyvnc-frontend-config-") as temporary:
        directory = Path(temporary)
        env["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")

        def reject(name, source, options, message, developer=None, generator="Ninja"):
            nonlocal checks
            result = subprocess.run(["cmake", "-S", str(source), "-B", str(directory / name),
                                     "-G", generator, *options], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    env=dict(env, DEVELOPER_DIR=developer or args.developer_dir))
            if result.returncode == 0 or message not in " ".join(result.stdout.split()):
                raise RuntimeError(f"{name}: expected rejection '{message}'\n{result.stdout}")
            checks += 1
            print(f"PASS {name}: {message}", flush=True)

        native = ["-DTIDYVNC_UI=SWIFTUI", "-DBUILD_VIEWER=ON", "-DBUILD_PLATFORM_APPS=OFF"]
        reject("invalid-selector", ROOT, ["-DTIDYVNC_UI=invalid"],
               "TIDYVNC_UI must be FLTK or SWIFTUI")
        reject("unsupported-generator", ROOT, native,
               "requires the single-configuration Ninja generator", generator="Unix Makefiles")
        reject("unsupported-configuration", ROOT, native + ["-DCMAKE_BUILD_TYPE=RelWithDebInfo"],
               "supports CMAKE_BUILD_TYPE=Debug or Release")
        reject("unsupported-floor", ROOT, native + ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"],
               "requires a macOS deployment target of 14.0 or later")
        reject("missing-swift", ROOT, native + ["-DCMAKE_Swift_COMPILER=NOTFOUND"],
               "BUILD_MACOS_NATIVE requires a Swift 6 toolchain")
        reject("missing-xcode", ROOT, native,
               "missing DEVELOPER_DIR path", developer=str(directory / "no-xcode"))
        # A real CLT installation must also be rejected, even though it has Swift.
        if Path("/Library/Developer/CommandLineTools").exists():
            reject("command-line-tools-only", ROOT, native,
                   "requires full Xcode, not only Command Line Tools",
                   developer="/Library/Developer/CommandLineTools")

        settings = {name: cache[f"CMAKE_OSX_{name}"] for name in
                    ("SYSROOT", "ARCHITECTURES", "DEPLOYMENT_TARGET")}
        changes = {"SYSROOT": "", "ARCHITECTURES": "x86_64" if settings["ARCHITECTURES"] == "arm64" else "arm64",
                   "DEPLOYMENT_TARGET": "15.0" if settings["DEPLOYMENT_TARGET"] != "15.0" else "14.0"}
        for name, value in changes.items():
            changed = dict(settings, **{name: value})
            # CMake resolves an empty SDK to the current SDK. Use an existing
            # directory instead, so project() succeeds and the handoff guard runs.
            if name == "SYSROOT":
                alias = directory / "sdk-alias"
                alias.symlink_to(settings[name], target_is_directory=True)
                changed[name] = str(alias)
            reject(f"app-mismatched-{name.lower()}", ROOT / "apps/macos",
                   [f"-DNATIVE_CORE_BUILD={core}",
                    *(f"-DCMAKE_OSX_{key}={setting}" for key, setting in changed.items())],
                   f"App CMAKE_OSX_{name} must match the configured native core", generator="Xcode")
    print(f"PASS {checks} real configure rejection checks")


if __name__ == "__main__":
    main()
