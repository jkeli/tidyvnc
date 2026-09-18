if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  message(FATAL_ERROR "cmake must be invoked with the top level directory")
endif()

add_library(test_util STATIC util.cxx)

add_executable(convperf convperf.cxx)
target_link_libraries(convperf test_util rfb)

add_executable(decperf decperf.cxx)
target_link_libraries(decperf test_util rdr rfb rfbclient)

add_executable(encperf encperf.cxx)
target_link_libraries(encperf test_util core rdr rfb rfbclient rfbserver)

if (BUILD_VIEWER)
  add_executable(fbperf
    fbperf.cxx
    ${CMAKE_SOURCE_DIR}/vncviewer/PlatformPixelBuffer.cxx
    ${CMAKE_SOURCE_DIR}/vncviewer/Surface.cxx)
  if(WIN32)
    target_sources(fbperf PRIVATE ${CMAKE_SOURCE_DIR}/vncviewer/Surface_Win32.cxx)
  elseif(APPLE)
    target_sources(fbperf PRIVATE
      ${CMAKE_SOURCE_DIR}/vncviewer/Surface_OSX.cxx
      ${CMAKE_SOURCE_DIR}/vncviewer/keysym2ucs.c
      ${CMAKE_SOURCE_DIR}/vncviewer/cocoa.mm)
  else()
    target_sources(fbperf PRIVATE ${CMAKE_SOURCE_DIR}/vncviewer/Surface_X11.cxx)
  endif()
  # Prefer the selected FLTK headers over another installation in a generic
  # system include directory (e.g. Homebrew's prefix).
  target_include_directories(fbperf SYSTEM BEFORE PRIVATE ${FLTK_INCLUDE_DIRS})
  target_link_libraries(fbperf test_util core rfb ${TIDYVNC_FLTK_TARGET})
  if(WIN32)
    target_compile_definitions(fbperf PRIVATE NOMINMAX)
    target_link_libraries(fbperf msimg32)
  endif()
  if(APPLE)
    target_link_libraries(fbperf "-framework Cocoa")
    target_link_libraries(fbperf "-framework Carbon")
    target_link_libraries(fbperf "-framework IOKit")
  endif()
endif()

add_executable(scalingperf scalingperf.cxx ../../vncviewer/DesktopResampler.cxx ../../vncviewer/DesktopTileCache.cxx)
target_include_directories(scalingperf PRIVATE ${CMAKE_SOURCE_DIR}/vncviewer)
target_link_libraries(scalingperf core)
