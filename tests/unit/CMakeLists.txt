if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  message(FATAL_ERROR "cmake must be invoked with the top level directory")
endif()

include(GoogleTest)

# Google Test requires a new C++ standard
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++17")

enable_testing()

include_directories(${CMAKE_SOURCE_DIR}/vncviewer)

add_executable(configargs configargs.cxx)
target_link_libraries(configargs rfb GTest::gtest_main)
gtest_discover_tests(configargs)

add_executable(conv conv.cxx)
target_link_libraries(conv rfb GTest::gtest_main)
gtest_discover_tests(conv)

add_executable(convertlf convertlf.cxx)
target_link_libraries(convertlf core GTest::gtest_main)
gtest_discover_tests(convertlf)

add_executable(gesturehandler gesturehandler.cxx ../../vncviewer/GestureHandler.cxx)
target_link_libraries(gesturehandler core GTest::gtest_main)
gtest_discover_tests(gesturehandler)

add_executable(hostport hostport.cxx)
target_link_libraries(hostport network GTest::gtest_main)
gtest_discover_tests(hostport)

add_executable(parameters parameters.cxx)
target_link_libraries(parameters core GTest::gtest_main)
gtest_discover_tests(parameters)

add_executable(pixelformat pixelformat.cxx)
target_link_libraries(pixelformat rfb GTest::gtest_main)
gtest_discover_tests(pixelformat)

add_executable(shortcuthandler shortcuthandler.cxx ../../vncviewer/ShortcutHandler.cxx)
target_link_libraries(shortcuthandler core ${Intl_LIBRARIES} GTest::gtest_main)
gtest_discover_tests(shortcuthandler)

add_executable(unicode unicode.cxx)
target_link_libraries(unicode core GTest::gtest_main)
gtest_discover_tests(unicode)

add_executable(emulatemb emulatemb.cxx ../../vncviewer/EmulateMB.cxx)
target_link_libraries(emulatemb core GTest::gtest_main)
gtest_discover_tests(emulatemb)

add_executable(desktoptransform desktoptransform.cxx ../../vncviewer/DesktopTransform.cxx)
target_link_libraries(desktoptransform core GTest::gtest_main)
gtest_discover_tests(desktoptransform)

add_executable(desktopresampler desktopresampler.cxx ../../vncviewer/DesktopResampler.cxx)
target_link_libraries(desktopresampler core GTest::gtest_main)
gtest_discover_tests(desktopresampler)

add_executable(desktoptilecache desktoptilecache.cxx ../../vncviewer/DesktopTileCache.cxx ../../vncviewer/DesktopResampler.cxx)
target_link_libraries(desktoptilecache core GTest::gtest_main)
gtest_discover_tests(desktoptilecache)
add_executable(cursorrenderer cursorrenderer.cxx ../../vncviewer/CursorRenderer.cxx ../../vncviewer/DesktopResampler.cxx)
target_link_libraries(cursorrenderer core GTest::gtest_main)
gtest_discover_tests(cursorrenderer)
add_executable(desktoplayout desktoplayout.cxx ../../vncviewer/DesktopLayout.cxx ../../vncviewer/DesktopTransform.cxx)
target_link_libraries(desktoplayout core GTest::gtest_main)
gtest_discover_tests(desktoplayout)
target_compile_definitions(desktoptransform PRIVATE
  DESKTOP_SCALING_FIXTURES="${CMAKE_SOURCE_DIR}/tests/fixtures/desktop-scaling.tsv")

# Native bitmap operations can be tested without opening a display on these
# platforms. X11 surfaces require a server and belong in the GUI matrix.
if(BUILD_VIEWER AND (APPLE OR WIN32))
  add_executable(surface surface.cxx ../../vncviewer/Surface.cxx)
  target_include_directories(surface SYSTEM BEFORE PRIVATE ${FLTK_INCLUDE_DIRS})
  target_link_libraries(surface core ${TIDYVNC_FLTK_TARGET} GTest::gtest_main)
  if(APPLE)
    target_sources(surface PRIVATE ../../vncviewer/Surface_OSX.cxx ../../vncviewer/cocoa.mm)
    target_link_libraries(surface "-framework Cocoa" "-framework Carbon" "-framework IOKit")
  else()
    target_sources(surface PRIVATE ../../vncviewer/Surface_Win32.cxx)
    target_compile_definitions(surface PRIVATE NOMINMAX)
    target_link_libraries(surface core msimg32)
  endif()
  gtest_discover_tests(surface)
endif()

if(BUILD_VIEWER AND NOT WIN32)
  add_executable(viewerstate viewerstate.cxx
    ../../vncviewer/parameters.cxx ../../vncviewer/LegacyImport.cxx
    ../../vncviewer/MonitorIndicesParameter.cxx ../../vncviewer/DesktopTransform.cxx)
  target_include_directories(viewerstate SYSTEM BEFORE PRIVATE ${FLTK_INCLUDE_DIRS})
  target_link_libraries(viewerstate rfbclient rfb network rdr core ${TIDYVNC_FLTK_TARGET} GTest::gtest_main)
  if(GNUTLS_FOUND)
    target_include_directories(viewerstate SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
  endif()
  gtest_discover_tests(viewerstate)
endif()
