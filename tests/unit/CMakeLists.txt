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

add_executable(d3des d3des.cxx)
find_package(Threads REQUIRED)
target_link_libraries(d3des rfb GTest::gtest_main Threads::Threads)
gtest_discover_tests(d3des)

add_executable(vncauth vncauth.cxx)
target_link_libraries(vncauth rfbclient GTest::gtest_main)
gtest_discover_tests(vncauth)

add_executable(tightdecoder tightdecoder.cxx)
target_link_libraries(tightdecoder rfbclient GTest::gtest_main Threads::Threads)
gtest_discover_tests(tightdecoder)

add_executable(securityclient securityclient.cxx)
target_link_libraries(securityclient rfbclient GTest::gtest_main Threads::Threads)
gtest_discover_tests(securityclient)

add_executable(security security.cxx)
target_link_libraries(security rfb GTest::gtest_main Threads::Threads)
gtest_discover_tests(security)

add_executable(connectionencoding connectionencoding.cxx)
target_link_libraries(connectionencoding rfbclient GTest::gtest_main Threads::Threads)
gtest_discover_tests(connectionencoding)

add_executable(clientclipboard clientclipboard.cxx)
target_link_libraries(clientclipboard rfbclient GTest::gtest_main Threads::Threads)
gtest_discover_tests(clientclipboard)

add_executable(clientcredentials clientcredentials.cxx)
target_link_libraries(clientcredentials rfb GTest::gtest_main Threads::Threads)
gtest_discover_tests(clientcredentials)

add_executable(framepublisher framepublisher.cxx)
target_link_libraries(framepublisher tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(framepublisher)

add_executable(protocolsession protocolsession.cxx)
target_link_libraries(protocolsession tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(protocolsession)

add_executable(promptauthentication promptauthentication.cxx)
target_link_libraries(promptauthentication tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(promptauthentication PROPERTIES TIMEOUT 30)

if(GNUTLS_FOUND AND NOT WIN32)
  add_executable(clienttls clienttls.cxx)
  target_link_libraries(clienttls rfbclient GTest::gtest_main Threads::Threads)
  gtest_discover_tests(clienttls)
endif()

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
target_link_libraries(emulatemb tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(emulatemb)

add_executable(desktoptransform desktoptransform.cxx)
target_link_libraries(desktoptransform tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(desktoptransform)

add_executable(desktopresampler desktopresampler.cxx)
target_link_libraries(desktopresampler tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(desktopresampler)

add_executable(desktoptilecache desktoptilecache.cxx)
target_link_libraries(desktoptilecache tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(desktoptilecache)
add_executable(cursorrenderer cursorrenderer.cxx)
target_link_libraries(cursorrenderer tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(cursorrenderer)
add_executable(desktoplayout desktoplayout.cxx)
target_link_libraries(desktoplayout tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(desktoplayout)
target_compile_definitions(desktoptransform PRIVATE
  DESKTOP_SCALING_FIXTURES="${CMAKE_SOURCE_DIR}/tests/fixtures/desktop-scaling.tsv")

# Native bitmap operations can be tested without opening a display on these
# platforms. X11 surfaces require a server and belong in the GUI matrix.
if(BUILD_VIEWER AND (APPLE OR WIN32))
  add_executable(surface surface.cxx ../../vncviewer/Surface.cxx)
  target_include_directories(surface SYSTEM BEFORE PRIVATE ${FLTK_INCLUDE_DIRS})
  target_link_libraries(surface tidyvnc_viewer_core ${TIDYVNC_FLTK_TARGET} GTest::gtest_main)
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
    ../../vncviewer/MonitorIndicesParameter.cxx)
  target_include_directories(viewerstate SYSTEM BEFORE PRIVATE ${FLTK_INCLUDE_DIRS})
  target_link_libraries(viewerstate tidyvnc_viewer_core ${TIDYVNC_FLTK_TARGET} GTest::gtest_main)
  if(GNUTLS_FOUND)
    target_include_directories(viewerstate SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
  endif()
  gtest_discover_tests(viewerstate)
endif()
