#!/usr/bin/env python3
"""Build the experimental native app with CMake core + Xcode app authority."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build/native-app"))
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    parser.add_argument("--deps", type=Path, help="Static dependency prefix from deps.py (default: build/native-deps/<arch>)")
    parser.add_argument("--prefix", default="/opt/homebrew", help="GoogleTest prefix for --test (default: /opt/homebrew)")
    parser.add_argument("--deployment-target", default="13.0")
    parser.add_argument("--parallel", type=int, default=4, help="Maximum concurrent build jobs (default: 4)")
    parser.add_argument("--test", action="store_true",
                        help="Require GoogleTest, build all tests, and verify every automated suite and the bundle")
    parser.add_argument("--package", action="store_true", help="Assemble a verified relocatable app and DMG after building/testing")
    parser.add_argument("--package-output", type=Path, help="New package directory (default: build-dir/package/configuration)")
    parser.add_argument("--package-minimum-os", help="Explicit package minimum; dependencies above this floor fail packaging")
    parser.add_argument("--sign-identity", default="-", help="Package signing identity (default: ad hoc)")
    parser.add_argument("--provisioning-profile", type=Path, help="The app's provisioning profile, for a signing identity")
    parser.add_argument("--notary-key", type=Path, help="App Store Connect API key (.p8); notarizes the package")
    parser.add_argument("--notary-key-id", help="The API key's ID")
    parser.add_argument("--notary-issuer", help="The API key's issuer ID")
    args = parser.parse_args()
    if args.parallel < 1:
        parser.error("--parallel must be positive")
    source = Path(__file__).resolve().parents[2]
    build = args.build_dir.resolve()
    core, app = build / "core", build / "app"
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
    env["CLANG_MODULE_CACHE_PATH"] = str(build / "ModuleCache")
    # The core links only the pinned static libraries; deps.py rebuilds them
    # when its recipe changes and otherwise returns at once.
    deps = (args.deps or source / "build/native-deps" / platform.machine()).resolve()
    subprocess.run([sys.executable, source / "apps/macos/deps.py", "--out", deps], check=True, env=env)
    env.pop("PKG_CONFIG_PATH", None)
    env["PKG_CONFIG_LIBDIR"] = str(deps / "lib/pkgconfig")
    prefixes = [str(deps)] + ([args.prefix] if args.test else [])

    def run(*command):
        subprocess.run([str(x) for x in command], check=True, env=env)

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
    common = [f"-DCMAKE_OSX_SYSROOT={sdk}", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={args.deployment_target}",
              f"-DCMAKE_OSX_ARCHITECTURES={platform.machine()}"]
    if args.test:
        for directory in (core, app):
            query = directory / ".cmake/api/v1/query"
            query.mkdir(parents=True, exist_ok=True)
            (query / "codemodel-v2").touch()
        common.append("-DCMAKE_REQUIRE_FIND_PACKAGE_GTest=TRUE")
    # Libraries found through a different prefix stay in the cache; start afresh.
    cache = core / "CMakeCache.txt"
    fresh = ["--fresh"] if cache.exists() and f"CMAKE_PREFIX_PATH:UNINITIALIZED={';'.join(prefixes)}\n" \
        not in cache.read_text() else []
    run("cmake", *fresh, "-S", source, "-B", core, "-G", "Ninja", *common,
        f"-DCMAKE_BUILD_TYPE={args.configuration}", f"-DCMAKE_PREFIX_PATH={';'.join(prefixes)}",
        "-DBUILD_VIEWER=ON", "-DTIDYVNC_UI=SWIFTUI", "-DBUILD_PLATFORM_APPS=OFF",
        f"-DTIDYVNC_NATIVE_APP_BUILD_DIR={app}",
        "-DENABLE_NLS=OFF", "-DENABLE_AUDIO=OFF", "-DENABLE_H264=OFF",
        "-DENABLE_GNUTLS=ON", "-DENABLE_NETTLE=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE",
        "-DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE")
    target = "all" if args.test else "vncviewer"
    run("cmake", "--build", core, "--target", target, "--parallel", args.parallel)
    bundle = app / args.configuration / "TidyVNC.app"
    print(f"Native app: {bundle}", flush=True)
    if args.test:
        run(sys.executable, source / "tests/macos/verify-build.py", "--core", core,
            "--app", bundle, "--reports", build / "verification")
    if args.package:
        command = [sys.executable, source / "apps/macos/package.py", "--app", bundle,
                   "--output", args.package_output or build / "package" / args.configuration,
                   "--deps", deps, "--sign-identity", args.sign_identity, "--dmg"]
        if args.package_minimum_os:
            command += ["--minimum-os", args.package_minimum_os]
        for option in ("provisioning_profile", "notary_key", "notary_key_id", "notary_issuer"):
            if getattr(args, option):
                command += ["--" + option.replace("_", "-"), getattr(args, option)]
        run(*command)


if __name__ == "__main__":
    main()
