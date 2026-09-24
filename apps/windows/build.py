#!/usr/bin/env python3
"""Build the Windows (WinUI) viewer: native core, .NET app, payload and MSI.

Modelled on apps/macos/build.py (plans/native-ui-winui/PACKAGING.md section 2).
Stages, each optional after the first:

  core      CMake + Ninja with MSVC (x64, or ARM64 with the MSVC ARM64 build
            tools): tidyvnc_viewer.dll, the Windows helper and the tests
  app       dotnet publish of apps/windows/TidyVNC and the CLI launcher
  package   payload assembly, dependency audit and the per-user MSI

Dependencies come from apps/windows/deps.py (MSYS2 DLLs) and, for tests,
vcpkg's GoogleTest. Output directories are created fresh or reused only when
they were created by this script for the same configuration.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolchain  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
VCPKG_ROOT = Path(os.environ.get("VCPKG_ROOT", r"C:\vcpkg"))


def run(command, env=None, cwd=ROOT):
    print("+ " + " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], check=True, env=env, cwd=cwd)


def ensure_dependencies(arch, test):
    deps = ROOT / "build/winui/deps" / arch
    if not (deps / "deps.json").exists():
        run([sys.executable, ROOT / "apps/windows/deps.py", "--arch", arch])
    prefixes = [deps]
    if test:
        installed = ROOT / "build/vcpkg_installed"
        triplet = f"{arch}-windows"
        if not (installed / triplet / "share/gtest").exists():
            if arch != "x64" and not toolchain.has_msvc_arm64():
                raise SystemExit("ARM64 tests need GoogleTest built with the MSVC ARM64 tools; "
                                 "build the ARM64 core without --test")
            run([VCPKG_ROOT / "vcpkg.exe", "install", "--triplet", triplet, f"--x-install-root={installed}"])
        prefixes.append(installed / triplet)
    return prefixes


def configure_core(args, build, env, prefixes):
    stamp = build / "tidyvnc-build.json"
    expected = {"arch": args.arch, "configuration": args.configuration, "asan": args.asan, "test": args.test}
    if build.exists() and not (stamp.exists() and json.loads(stamp.read_text()) == expected):
        raise SystemExit(f"{build} exists and was not created by build.py for {expected}; choose a new --build-dir")
    command = ["cmake", "-S", ROOT, "-B", build, "-G", "Ninja", *toolchain.cmake_compilers(args.arch, build=build),
               f"-DCMAKE_BUILD_TYPE={args.configuration}",
               "-DCMAKE_PREFIX_PATH=" + ";".join(p.as_posix() for p in prefixes),
               "-DBUILD_VIEWER=ON", "-DTIDYVNC_UI=WINUI", "-DBUILD_PLATFORM_APPS=OFF",
               "-DENABLE_NLS=OFF", "-DENABLE_AUDIO=OFF", "-DENABLE_H264=OFF",
               "-DENABLE_GNUTLS=ON", "-DENABLE_NETTLE=ON"]
    if args.asan:
        command.append("-DENABLE_ASAN=ON")
    if not args.test:
        command.append("-DCMAKE_DISABLE_FIND_PACKAGE_GTest=TRUE")
    else:
        command.append("-DCMAKE_REQUIRE_FIND_PACKAGE_GTest=TRUE")
    build.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(expected))
    run(command, env=env)


def build_core(args):
    build = (args.build_dir or ROOT / "build/winui" / f"core-{args.arch}-{args.configuration.lower()}").resolve()
    env = toolchain.environment(args.arch)
    prefixes = ensure_dependencies(args.arch, args.test)
    configure_core(args, build, env, prefixes)
    target = "all" if args.test else "tidyvnc_viewer_shared"
    run(["cmake", "--build", build, "--target", target, "--parallel", str(args.parallel)], env=env)
    if args.test:
        if args.arch != "x64":
            print("ARM64 binaries are cross-built; run their tests on ARM64 hardware.", flush=True)
        else:
            run(["ctest", "--test-dir", build / "tests/viewer", "--output-on-failure", "--no-tests=error"], env=env)
            run(["ctest", "--test-dir", build / "tests/unit", "-j", str(args.parallel), "--timeout", "180",
                 "--output-on-failure", "--no-tests=error"], env=env)
    return build


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arch", choices=toolchain.ARCHES, default="x64")
    parser.add_argument("--configuration", choices=("Debug", "Release", "RelWithDebInfo"), default="Debug")
    parser.add_argument("--build-dir", type=Path, help="Core build directory (default build/winui/core-<arch>-<config>)")
    parser.add_argument("--parallel", type=int, default=8)
    parser.add_argument("--test", action="store_true", help="Build and run the core and ABI test suites")
    parser.add_argument("--asan", action="store_true", help="AddressSanitizer build of the core and tests")
    parser.add_argument("--stages", default="core", help="Comma-separated: core, app, package")
    args = parser.parse_args()
    stages = [stage.strip() for stage in args.stages.split(",") if stage.strip()]
    unknown = set(stages) - {"core", "app", "package"}
    if unknown:
        parser.error(f"unknown stages: {sorted(unknown)}")
    core = build_core(args)
    print(f"Core: {core}", flush=True)
    if "app" in stages or "package" in stages:
        import app_build  # noqa: E402  (apps/windows/app_build.py)
        app = app_build.publish(args, core)
        print(f"App: {app}", flush=True)
        if "package" in stages:
            import package  # noqa: E402  (apps/windows/package.py)
            package.build(args, core, app)


if __name__ == "__main__":
    main()
