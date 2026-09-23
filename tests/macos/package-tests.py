#!/usr/bin/env python3
"""Dependency and failure-policy regressions without touching installed code."""
import argparse
import importlib.util
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
        dependency = binary(self.app / "Contents/Frameworks/liba.dylib", loads=["/usr/lib/libSystem.B.dylib"])
        binary(self.exe, loads=["@loader_path/../Frameworks/liba.dylib"], kind=2)
        self.assertEqual(len(pkg.audit(self.app, "14.0", "arm64")), 2)
        for load in (str(dependency), "@rpath/liba.dylib", "@loader_path/../../../absent.dylib"):
            binary(self.exe, loads=[load], kind=2)
            with self.assertRaises(pkg.PackageError):
                pkg.audit(self.app, "14.0", "arm64")
        binary(self.exe, rpaths=["/opt/homebrew/lib"], kind=2)
        with self.assertRaisesRegex(pkg.PackageError, "runpath"):
            pkg.audit(self.app, "14.0", "arm64")

    def test_dependency_licence_required_and_copied(self):
        dependency = binary(self.root / "keg/lib/liba.dylib")
        (self.root / "keg/INSTALL_RECEIPT.json").write_text("{}")
        target = self.root / "notices"
        with self.assertRaisesRegex(pkg.PackageError, "licence"):
            pkg.copy_notices(dependency, target, None)
        (self.root / "keg/LICENSE").write_text("Fixture licence")
        result = pkg.copy_notices(dependency, target, None)
        self.assertEqual((target / "LICENSE").read_text(), "Fixture licence")
        self.assertEqual(result["LICENSE"], pkg.digest(target / "LICENSE"))

    def test_failed_package_does_not_publish_or_mutate_input(self):
        info = {"CFBundleIdentifier": "io.github.jkeli.tidyvnc", "CFBundleExecutable": "vncviewer",
                "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "14.0"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        source = self.exe.read_bytes()
        output = self.root / "package"
        args = argparse.Namespace(app=self.app, output=output, minimum_os=None,
                                  sign_identity="-", dependency_notices=None, dmg=False)
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
