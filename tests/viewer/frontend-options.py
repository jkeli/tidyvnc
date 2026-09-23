#!/usr/bin/env python3
"""Exercise frontend policy using CMake itself, without platform dependencies."""
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE = ROOT / "cmake/ViewerFrontend.cmake"


class FrontendSelection(unittest.TestCase):
    def evaluate(self, body, expected=None):
        with tempfile.TemporaryDirectory(prefix="tidyvnc-frontend-") as directory:
            script = pathlib.Path(directory) / "selection.cmake"
            script.write_text("cmake_minimum_required(VERSION 3.15)\n" +
                              body.replace("@MODULE@", MODULE.as_posix()))
            result = subprocess.run(["cmake", "-P", str(script)], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if expected:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(expected, result.stdout)
        else:
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_default_and_explicit_fltk_on_all_platforms(self):
        for apple in ("ON", "OFF"):
            for viewer in ("ON", "AUTO", "OFF"):
                with self.subTest(apple=apple, viewer=viewer):
                    self.evaluate(f"""
set(APPLE {apple})
set(BUILD_VIEWER {viewer})
set(BUILD_MACOS_NATIVE OFF)
include("@MODULE@")
if(NOT TIDYVNC_UI STREQUAL "FLTK" OR BUILD_SWIFTUI_VIEWER OR BUILD_MACOS_NATIVE)
  message(FATAL_ERROR "Default changed")
endif()
if(BUILD_VIEWER AND NOT BUILD_FLTK_VIEWER OR NOT BUILD_VIEWER AND BUILD_FLTK_VIEWER)
  message(FATAL_ERROR "Viewer enablement changed")
endif()
set(TIDYVNC_UI FLTK)
include("@MODULE@")
""")

    def test_native_selection_and_viewer_off(self):
        for viewer in ("ON", "AUTO", "OFF"):
            with self.subTest(viewer=viewer):
                self.evaluate(f"""
set(APPLE ON)
set(BUILD_VIEWER {viewer})
set(BUILD_MACOS_NATIVE OFF CACHE BOOL "")
set(TIDYVNC_UI SWIFTUI)
include("@MODULE@")
if(BUILD_FLTK_VIEWER OR NOT BUILD_VIEWER STREQUAL "{viewer}")
  message(FATAL_ERROR "Native selection modified viewer intent or enabled FLTK")
endif()
if(BUILD_VIEWER AND (NOT BUILD_SWIFTUI_VIEWER OR NOT BUILD_MACOS_NATIVE))
  message(FATAL_ERROR "Native app/bridge not enabled")
endif()
if(NOT BUILD_VIEWER AND (BUILD_SWIFTUI_VIEWER OR BUILD_MACOS_NATIVE))
  message(FATAL_ERROR "Disabled viewer enabled native targets")
endif()
get_property(cached CACHE BUILD_MACOS_NATIVE PROPERTY VALUE)
if(cached)
  message(FATAL_ERROR "Native selection overwrote bridge-only preference")
endif()
""")

    def test_bridge_only_does_not_select_app(self):
        self.evaluate("""
set(APPLE ON)
set(BUILD_VIEWER OFF)
set(BUILD_MACOS_NATIVE ON)
include("@MODULE@")
if(BUILD_FLTK_VIEWER OR BUILD_SWIFTUI_VIEWER OR NOT BUILD_MACOS_NATIVE)
  message(FATAL_ERROR "Bridge-only mode changed")
endif()
""")

    def test_non_apple_native_is_always_rejected(self):
        for viewer in ("ON", "AUTO", "OFF"):
            with self.subTest(viewer=viewer):
                self.evaluate(f"""
set(APPLE OFF)
set(BUILD_VIEWER {viewer})
set(TIDYVNC_UI SWIFTUI)
include("@MODULE@")
""", "TIDYVNC_UI=SWIFTUI requires macOS")

    def test_unknown_values_are_rejected(self):
        for frontend in ("swiftui", "FLTK;SWIFTUI", "", "QT"):
            with self.subTest(frontend=frontend):
                self.evaluate(f"""
set(APPLE ON)
set(BUILD_VIEWER OFF)
set(TIDYVNC_UI "{frontend}")
include("@MODULE@")
""", "TIDYVNC_UI must be FLTK or SWIFTUI")


if __name__ == "__main__":
    unittest.main()
