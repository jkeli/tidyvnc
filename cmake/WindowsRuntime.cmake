# MSVC builds: put every executable in one directory and copy the dependency
# DLLs beside them, so tests (and gtest discovery at build time) run without
# changing PATH. Packaging assembles its own payload (apps/windows/build.py).
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(TIDYVNC_RUNTIME_DLL_DIRS "" CACHE STRING
  "Directories whose DLLs are copied next to MSVC executables (default: <prefix>/bin for each CMAKE_PREFIX_PATH entry)")
set(_tidyvnc_dll_dirs ${TIDYVNC_RUNTIME_DLL_DIRS})
if(NOT _tidyvnc_dll_dirs)
  foreach(prefix ${CMAKE_PREFIX_PATH})
    # vcpkg keeps Debug DLLs (for example gtest) under debug/bin.
    if(CMAKE_BUILD_TYPE STREQUAL "Debug" AND IS_DIRECTORY "${prefix}/debug/bin")
      list(APPEND _tidyvnc_dll_dirs "${prefix}/debug/bin")
    endif()
    list(APPEND _tidyvnc_dll_dirs "${prefix}/bin")
  endforeach()
endif()
file(MAKE_DIRECTORY ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
set(_tidyvnc_copied)
foreach(dir ${_tidyvnc_dll_dirs})
  file(GLOB _dlls "${dir}/*.dll")
  foreach(dll ${_dlls})
    get_filename_component(name "${dll}" NAME)
    # The first directory providing a DLL wins (Debug before Release).
    list(FIND _tidyvnc_copied "${name}" found)
    if(found EQUAL -1)
      list(APPEND _tidyvnc_copied "${name}")
      file(COPY "${dll}" DESTINATION ${CMAKE_RUNTIME_OUTPUT_DIRECTORY})
    endif()
  endforeach()
endforeach()
