if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  message(FATAL_ERROR "cmake must be invoked with the top level directory")
endif()

# MSVC: report Debug CRT asserts and abort() on stderr instead of dialogs in
# every executable below (object files keep the static initializer).
if(MSVC)
  add_library(tidyvnc_msvc_crt_reports OBJECT ${CMAKE_SOURCE_DIR}/common/compat/msvc/crt_reports.cxx)
  link_libraries(tidyvnc_msvc_crt_reports)
endif()

# Benchmarking tools
add_subdirectory(perf)

# Always build the independent consumer; no GoogleTest or GUI is required.
add_subdirectory(viewer)
if(BUILD_MACOS_NATIVE)
  add_subdirectory(macos)
endif()

# Unit tests
if(GTest_FOUND)
  add_subdirectory(unit)
endif()
