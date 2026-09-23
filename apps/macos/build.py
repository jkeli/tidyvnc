#!/usr/bin/env python3
"""Build the experimental native app with CMake core + Xcode app authority."""
import argparse
import os
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build/native-app"))
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    parser.add_argument("--prefix", default="/opt/homebrew")
    parser.add_argument("--deployment-target", default="14.0")
    args = parser.parse_args()
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
    run("cmake", "-S", source, "-B", core, "-G", "Ninja", *common,
        f"-DCMAKE_BUILD_TYPE={args.configuration}", f"-DCMAKE_PREFIX_PATH={args.prefix}",
        "-DBUILD_VIEWER=OFF", "-DBUILD_PLATFORM_APPS=OFF", "-DBUILD_MACOS_NATIVE=ON",
        "-DENABLE_NLS=OFF", "-DENABLE_AUDIO=OFF", "-DENABLE_H264=OFF",
        "-DENABLE_GNUTLS=ON", "-DENABLE_NETTLE=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_FLTK=TRUE",
        "-DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE")
    run("cmake", "--build", core, "--target", "tidyvnc_macos_bridge", "tidyvnc-ssh-askpass", "--parallel", "4")
    run("cmake", "-S", source / "apps/macos", "-B", app, "-G", "Xcode", *common,
        f"-DNATIVE_CORE_BUILD={core}")
    run("xcodebuild", "-project", app / "TidyVNCNativeApp.xcodeproj", "-scheme", "TidyVNC",
        "-configuration", args.configuration, "-derivedDataPath", build / "DerivedData", "build")
    run("python3", source / "tests/macos/localization-source.py", source / "apps/macos/Localizable.xcstrings",
        "--module", core / "platform/macos/LocalizationSources.txt", core / "platform/macos/localization",
        "--module", app / "LocalizationSources.txt", app / "build/TidyVNC.build" / args.configuration)
    print(f"Native app: {app / args.configuration / 'TidyVNC.app'}")


if __name__ == "__main__":
    main()
