#!/usr/bin/env python3
"""Dependency and failure-policy regressions without touching installed code."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native_package", Path(__file__).resolve().parents[2] / "apps/macos/package.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def string_command(kind, value):
    data = value.encode() + b"\0"
    data += b"\0" * (-(24 + len(data)) % 8)
    return struct.pack("<IIIIII", kind, 24 + len(data), 24, 0, 0, 0) + data


def binary(path, loads=(), rpaths=(), minimum=14, arch=0x0100000C, kind=6):
    commands = [struct.pack("<IIIIII", 0x32, 24, 1, minimum << 16, 27 << 16, 0)]
    commands += [string_command(0xC, value) for value in loads]
    commands += [string_command(0x8000001C, value) for value in rpaths]
    if kind == 6:
        commands += [string_command(0xD, str(path))]
    data = b"".join(commands)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<IIIIIIII", 0xFEEDFACF, arch, 0, kind, len(commands), len(data), 0, 0) + data)
    return path


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tidyvnc-package-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.app = self.root / "TidyVNC.app"
        self.exe = self.app / "Contents/MacOS/vncviewer"
        binary(self.exe, kind=2)
        self.deps = self.root / "deps-prefix"
        library = self.deps / "lib/libx.a"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"!<arch>\n")
        licences = self.deps / "share/licenses/x"
        licences.mkdir(parents=True)
        (licences / "COPYING").write_text("Fixture licence")
        self.manifest = {"architecture": "arm64", "deploymentTarget": "13.0",
                         "libraries": {"libx.a": {"sha256": pkg.digest(library)}},
                         "packages": {"x": {"version": "1.0", "url": "https://example.org/x-1.0.tar.gz",
                                            "sha256": "ab" * 32, "licence_dir": "share/licenses/x"}}}
        self.write_manifest()

    def write_manifest(self):
        (self.deps / "deps.json").write_text(json.dumps(self.manifest))

    def graph(self, minimum="14.0"):
        return pkg.dependency_graph(self.app, self.exe, minimum)

    def test_macho_metadata_and_weak_reexports(self):
        binary(self.exe, loads=["/usr/lib/libSystem.B.dylib"], rpaths=["@executable_path/../Frameworks"], kind=2)
        data = self.exe.read_bytes()
        for command in (0x80000018, 0x8000001F, 0x80000023):
            with self.subTest(command=command):
                self.exe.write_bytes(data.replace(struct.pack("<I", 0xC), struct.pack("<I", command), 1))
                info = pkg.macho(self.exe)
                self.assertEqual(info["loads"], ["/usr/lib/libSystem.B.dylib"])
                self.assertEqual(info["rpaths"], ["@executable_path/../Frameworks"])
                self.assertEqual(info["architecture"], "arm64")
                self.assertEqual(info["minimumOS"], "14.0.0")

    def test_corrupt_and_unsupported_binaries_rejected(self):
        original = self.exe.read_bytes()
        variants = [b"", original[:31], original[:40], b"\xca\xfe\xba\xbe" + original[4:],
                    original[:20] + struct.pack("<I", 0xFFFFFFFF) + original[24:],
                    original[:36] + struct.pack("<I", 0) + original[40:],
                    original[:40] + struct.pack("<I", 2) + original[44:]]
        for data in variants:
            with self.subTest(data=data):
                self.exe.write_bytes(data)
                with self.assertRaises(pkg.PackageError):
                    pkg.macho(self.exe)

    def test_transitive_cycle_and_aliases_are_deduplicated(self):
        first = self.root / "deps/liba.1.dylib"
        second = self.root / "deps/libb.2.dylib"
        binary(first, loads=[str(second)])
        binary(second, loads=[str(first), "/usr/lib/libSystem.B.dylib"])
        alias = self.root / "deps/liba.dylib"
        alias.symlink_to(first.name)
        binary(self.exe, loads=[str(first), str(alias)], kind=2)
        nodes, architecture = self.graph()
        self.assertEqual(len(nodes), 3)
        self.assertEqual(architecture, "arm64")
        self.assertEqual(nodes[first]["edges"][str(second)], second)

    def test_nested_inherited_runpaths_use_owning_loader(self):
        dependency = binary(self.root / "deps/liba.dylib", loads=["@rpath/libb.dylib"], rpaths=["@loader_path/nested"])
        leaf = binary(self.root / "deps/nested/libb.dylib", loads=["@rpath/libc.dylib"])
        binary(self.root / "deps/nested/libc.dylib")
        binary(self.exe, loads=["@rpath/liba.dylib"], rpaths=[str(self.root / "deps")], kind=2)
        nodes, _ = self.graph()
        self.assertEqual(len(nodes), 4)
        self.assertEqual(nodes[dependency]["edges"]["@rpath/libb.dylib"], leaf)

    def test_ambiguous_and_missing_runpaths_rejected(self):
        for folder in ("one", "two"):
            binary(self.root / folder / "liba.dylib")
        binary(self.exe, loads=["@rpath/liba.dylib"], rpaths=[str(self.root / "one"), str(self.root / "two")], kind=2)
        with self.assertRaisesRegex(pkg.PackageError, "ambiguous"):
            self.graph()
        binary(self.exe, loads=["@rpath/absent.dylib"], kind=2)
        with self.assertRaisesRegex(pkg.PackageError, "Unresolved"):
            self.graph()

    def test_distinct_same_name_collision_rejected(self):
        paths = [binary(self.root / folder / "liba.dylib") for folder in ("one", "two")]
        binary(self.exe, loads=list(map(str, paths)), kind=2)
        with self.assertRaisesRegex(pkg.PackageError, "collision"):
            self.graph()

    def test_dependency_floor_architecture_and_fltk_enforced(self):
        dependency = self.root / "deps/liba.dylib"
        binary(self.exe, loads=[str(dependency)], kind=2)
        for kwargs, message in [({"minimum": 27}, "above package"), ({"arch": 0x01000007}, "Architecture"),
                                ({"loads": ["/usr/lib/libfltk.dylib"]}, "FLTK")]:
            with self.subTest(kwargs=kwargs):
                binary(dependency, **kwargs)
                with self.assertRaisesRegex(pkg.PackageError, message):
                    self.graph()
        binary(dependency, minimum=27)
        self.assertEqual(len(self.graph("27.0")[0]), 2)

    def test_bundle_symlink_escape_rejected(self):
        external = binary(self.root / "external.dylib")
        (self.app / "escape").symlink_to(external)
        with self.assertRaisesRegex(pkg.PackageError, "symlink escapes"):
            self.graph()

    def test_system_classification_is_normalized(self):
        self.assertTrue(pkg.system_path("/usr/lib/libSystem.B.dylib"))
        self.assertTrue(pkg.system_path("/System/Library/Frameworks/AppKit.framework/AppKit"))
        for path in ("/usr/lib/../../tmp/evil.dylib", "/usr/library/evil", "@rpath/libSystem.B.dylib", "/System/Library/../../tmp/evil"):
            self.assertFalse(pkg.system_path(path))

    def test_audit_requires_closed_relative_graph(self):
        dependency = binary(self.app / "Contents/MacOS/liba.dylib", loads=["/usr/lib/libSystem.B.dylib"])
        binary(self.exe, loads=["@loader_path/liba.dylib"], kind=2)
        self.assertEqual(len(pkg.audit(self.app, "14.0", "arm64")), 2)
        for load in (str(dependency), "@rpath/liba.dylib", "@loader_path/../../../absent.dylib"):
            binary(self.exe, loads=[load], kind=2)
            with self.assertRaises(pkg.PackageError):
                pkg.audit(self.app, "14.0", "arm64")
        binary(self.exe, rpaths=["/opt/homebrew/lib"], kind=2)
        with self.assertRaisesRegex(pkg.PackageError, "runpath"):
            pkg.audit(self.app, "14.0", "arm64")

    def test_audit_rejects_frameworks(self):
        binary(self.app / "Contents/Frameworks/liba.dylib")
        with self.assertRaisesRegex(pkg.PackageError, "Frameworks"):
            pkg.audit(self.app, "14.0", "arm64")

    def test_static_dependency_manifest_matches_prefix(self):
        self.assertEqual(pkg.static_dependencies(self.deps, "arm64", "13.0"), self.manifest)
        with self.assertRaisesRegex(pkg.PackageError, "x86_64"):
            pkg.static_dependencies(self.deps, "x86_64", "13.0")
        with self.assertRaisesRegex(pkg.PackageError, "above package minimum"):
            pkg.static_dependencies(self.deps, "arm64", "12.0")
        (self.deps / "lib/libx.a").write_bytes(b"changed")
        with self.assertRaisesRegex(pkg.PackageError, "differs"):
            pkg.static_dependencies(self.deps, "arm64", "13.0")
        (self.deps / "deps.json").unlink()
        with self.assertRaisesRegex(pkg.PackageError, "deps.py"):
            pkg.static_dependencies(self.deps, "arm64", "13.0")

    def test_dependency_licences_and_sources_recorded(self):
        target = self.root / "ThirdParty"
        records = pkg.copy_notices(self.deps, self.manifest, target)
        self.assertEqual((target / "x/COPYING").read_text(), "Fixture licence")
        self.assertEqual(records, [{"name": "x", "version": "1.0", "linkage": "static",
                                    "source": "https://example.org/x-1.0.tar.gz", "sourceSHA256": "ab" * 32,
                                    "notices": {"COPYING": pkg.digest(target / "x/COPYING")}}])
        self.assertIn("https://example.org/x-1.0.tar.gz", (target / "README.txt").read_text())
        (self.deps / "share/licenses/x/COPYING").unlink()
        with self.assertRaisesRegex(pkg.PackageError, "licence"):
            pkg.copy_notices(self.deps, self.manifest, self.root / "empty")
        self.manifest["packages"]["x"]["licence_dir"] = "../../escape"
        with self.assertRaisesRegex(pkg.PackageError, "licence"):
            pkg.copy_notices(self.deps, self.manifest, self.root / "escape")

    def package_args(self, output):
        info = {"CFBundleIdentifier": "io.github.jkeli.tidyvnc", "CFBundleExecutable": "vncviewer",
                "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "14.0"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return argparse.Namespace(app=self.app, output=output, minimum_os=None,
                                  sign_identity="-", deps=self.deps, dmg=False)

    def test_dynamic_third_party_library_rejected(self):
        binary(self.exe, loads=[str(binary(self.root / "keg/lib/liba.dylib"))], kind=2)
        output = self.root / "package"
        with self.assertRaisesRegex(pkg.PackageError, "statically"):
            pkg.package(self.package_args(output))
        self.assertFalse(output.exists())

    def test_failed_package_does_not_publish_or_mutate_input(self):
        output = self.root / "package"
        args = self.package_args(output)
        source = self.exe.read_bytes()
        with patch.object(pkg, "run", side_effect=OSError("Injected copy failure")):
            with self.assertRaisesRegex(OSError, "Injected"):
                pkg.package(args)
        self.assertFalse(output.exists())
        self.assertEqual(self.exe.read_bytes(), source)
        self.assertEqual(list(self.root.glob(".tidyvnc-package-*")), [])
        output.mkdir()
        (output / "keep").write_text("unchanged")
        with self.assertRaisesRegex(pkg.PackageError, "already exists"):
            pkg.package(args)
        self.assertEqual((output / "keep").read_text(), "unchanged")
        args.output = self.root / "lower"
        args.minimum_os = "13.0"
        with self.assertRaisesRegex(pkg.PackageError, "below"):
            pkg.package(args)

    def test_publication_never_replaces_existing_directory(self):
        source, destination = self.root / "ready", self.root / "published"
        source.mkdir()
        (source / "evidence").write_text("verified")
        destination.mkdir()
        with self.assertRaises(FileExistsError):
            pkg.publish(source, destination)
        self.assertTrue(source.is_dir())
        self.assertEqual(list(destination.iterdir()), [])
        destination.rmdir()
        pkg.publish(source, destination)
        self.assertFalse(source.exists())
        self.assertEqual((destination / "evidence").read_text(), "verified")


if __name__ == "__main__":
    unittest.main()
