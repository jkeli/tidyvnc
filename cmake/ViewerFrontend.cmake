# Keep selection independent of dependency discovery, so an explicit unsupported
# frontend never silently falls back to another one (including BUILD_VIEWER=AUTO).
if(NOT DEFINED TIDYVNC_UI)
  set(TIDYVNC_UI FLTK)
endif()
set(TIDYVNC_UI "${TIDYVNC_UI}" CACHE STRING "Viewer frontend: FLTK or SWIFTUI")
set_property(CACHE TIDYVNC_UI PROPERTY STRINGS FLTK SWIFTUI)
if(NOT TIDYVNC_UI STREQUAL "FLTK" AND NOT TIDYVNC_UI STREQUAL "SWIFTUI")
  message(FATAL_ERROR "TIDYVNC_UI must be FLTK or SWIFTUI; got '${TIDYVNC_UI}'")
endif()
if(TIDYVNC_UI STREQUAL "SWIFTUI" AND NOT APPLE)
  message(FATAL_ERROR "TIDYVNC_UI=SWIFTUI requires macOS; use FLTK on other platforms")
endif()

# Derived, non-cache values. Do not rewrite the user's BUILD_VIEWER or bridge-only
# preference when switching frontends in an existing build directory.
set(BUILD_FLTK_VIEWER OFF)
set(BUILD_SWIFTUI_VIEWER OFF)
if(BUILD_VIEWER)
  if(TIDYVNC_UI STREQUAL "SWIFTUI")
    set(BUILD_SWIFTUI_VIEWER ON)
    set(BUILD_MACOS_NATIVE ON)
  else()
    set(BUILD_FLTK_VIEWER ON)
  endif()
endif()
