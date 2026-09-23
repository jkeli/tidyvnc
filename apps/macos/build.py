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
    parser.add_argument("--prefix", default="/opt/homebrew")
    parser.add_argument("--deployment-target", default="14.0")
    parser.add_argument("--parallel", type=int, default=4, help="Maximum concurrent build jobs (default: 4)")
    parser.add_argument("--test", action="store_true",
                        help="Require GoogleTest, build all tests, and verify every automated suite and the bundle")
    args = parser.parse_args()
    if args.parallel < 1:
        parser.error("--parallel must be positive")
    source = Path(__file__).resolve().parents[2]
    build = args.build_dir.resolve()
    core, app = build / "core", build / "app"
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
    env["CLANG_MODULE_CACHE_PATH"] = str(build / "ModuleCache")

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
    run("cmake", "-S", source, "-B", core, "-G", "Ninja", *common,
        f"-DCMAKE_BUILD_TYPE={args.configuration}", f"-DCMAKE_PREFIX_PATH={args.prefix}",
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


if __name__ == "__main__":
    main()
