# Keep selection independent of dependency discovery, so an explicit unsupported
# frontend never silently falls back to another one (including BUILD_VIEWER=AUTO).
if(NOT DEFINED TIDYVNC_UI)
  set(TIDYVNC_UI FLTK)
endif()
set(TIDYVNC_UI "${TIDYVNC_UI}" CACHE STRING "Viewer frontend: FLTK, SWIFTUI or WINUI")
set_property(CACHE TIDYVNC_UI PROPERTY STRINGS FLTK SWIFTUI WINUI)
if(NOT TIDYVNC_UI STREQUAL "FLTK" AND NOT TIDYVNC_UI STREQUAL "SWIFTUI" AND NOT TIDYVNC_UI STREQUAL "WINUI")
  message(FATAL_ERROR "TIDYVNC_UI must be FLTK, SWIFTUI or WINUI; got '${TIDYVNC_UI}'")
endif()
if(TIDYVNC_UI STREQUAL "SWIFTUI" AND NOT APPLE)
  message(FATAL_ERROR "TIDYVNC_UI=SWIFTUI requires macOS; use FLTK on other platforms")
endif()
# The WinUI app itself is built by dotnet (apps/windows/build.py); CMake builds
# its native DLLs and never discovers or links FLTK.
if(TIDYVNC_UI STREQUAL "WINUI" AND NOT WIN32)
  message(FATAL_ERROR "TIDYVNC_UI=WINUI requires Windows; use FLTK on other platforms")
endif()
if(TIDYVNC_UI STREQUAL "WINUI" AND NOT MSVC)
  message(FATAL_ERROR "TIDYVNC_UI=WINUI requires MSVC or clang-cl (see plans/native-ui-winui/CORE.md)")
endif()

# Derived, non-cache values. Do not rewrite the user's BUILD_VIEWER or bridge-only
# preference when switching frontends in an existing build directory.
set(BUILD_FLTK_VIEWER OFF)
set(BUILD_SWIFTUI_VIEWER OFF)
set(BUILD_WINUI_VIEWER OFF)
if(BUILD_VIEWER)
  if(TIDYVNC_UI STREQUAL "SWIFTUI")
    set(BUILD_SWIFTUI_VIEWER ON)
    set(BUILD_MACOS_NATIVE ON)
  elseif(TIDYVNC_UI STREQUAL "WINUI")
    set(BUILD_WINUI_VIEWER ON)
  else()
    set(BUILD_FLTK_VIEWER ON)
  endif()
endif()
