if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  message(FATAL_ERROR "cmake must be invoked with the top level directory")
endif()

include(GoogleTest)

# Match the selected GoogleTest library even when another dependency adds a
# broad include prefix containing a different GoogleTest installation.
get_target_property(TIDYVNC_GTEST_INCLUDE_DIRS GTest::gtest INTERFACE_INCLUDE_DIRECTORIES)
include_directories(BEFORE SYSTEM ${TIDYVNC_GTEST_INCLUDE_DIRS})

# Google Test requires a new C++ standard (MSVC builds already use C++17)
if(NOT MSVC)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++17")
endif()

enable_testing()

include_directories(${CMAKE_SOURCE_DIR}/vncviewer)

add_executable(logging logging.cxx)
target_link_libraries(logging core GTest::gtest_main Threads::Threads)
gtest_discover_tests(logging)

add_executable(configargs configargs.cxx)
target_link_libraries(configargs rfb GTest::gtest_main)
gtest_discover_tests(configargs)

add_executable(windowgeometry windowgeometry.cxx)
target_link_libraries(windowgeometry tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(windowgeometry)

add_executable(invocation invocation.cxx)
target_link_libraries(invocation tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(invocation)

add_executable(loggingpolicy loggingpolicy.cxx)
target_link_libraries(loggingpolicy tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(loggingpolicy)

add_executable(redactedlogger redactedlogger.cxx)
target_link_libraries(redactedlogger tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(redactedlogger)

add_executable(startuplogging startuplogging.cxx)
target_link_libraries(startuplogging tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(startuplogging)

add_executable(invocationabi invocationabi.cxx ../viewer/c-abi-test-support.cxx)
target_link_libraries(invocationabi tidyvnc_viewer_c GTest::gtest_main Threads::Threads)
gtest_discover_tests(invocationabi)

add_executable(connectiondocument connectiondocument.cxx)
target_link_libraries(connectiondocument tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(connectiondocument)

add_executable(documentabi documentabi.cxx ../viewer/c-abi-test-support.cxx)
target_link_libraries(documentabi tidyvnc_viewer_c GTest::gtest_main Threads::Threads)
gtest_discover_tests(documentabi)

add_executable(conv conv.cxx)
target_link_libraries(conv rfb GTest::gtest_main)
gtest_discover_tests(conv)

add_executable(d3des d3des.cxx)
find_package(Threads REQUIRED)
target_link_libraries(d3des rfb GTest::gtest_main Threads::Threads)
gtest_discover_tests(d3des)

add_executable(wipe wipe.cxx)
target_link_libraries(wipe core GTest::gtest_main)
gtest_discover_tests(wipe)

add_executable(encodingroundtrip encodingroundtrip.cxx)
target_link_libraries(encodingroundtrip rfbclient rfbserver rfb rdr core GTest::gtest_main Threads::Threads)
gtest_discover_tests(encodingroundtrip)

add_executable(sshgateway sshgateway.cxx)
target_link_libraries(sshgateway tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(sshgateway)

add_executable(desktopsize desktopsize.cxx)
target_link_libraries(desktopsize tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(desktopsize)

add_executable(randomstream randomstream.cxx)
target_link_libraries(randomstream rdr GTest::gtest_main Threads::Threads)
gtest_discover_tests(randomstream)

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

add_executable(sessioninput sessioninput.cxx)
target_link_libraries(sessioninput tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessioninput PROPERTIES TIMEOUT 30)

add_executable(remotedesktoplayout remotedesktoplayout.cxx)
target_link_libraries(remotedesktoplayout tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(remotedesktoplayout PROPERTIES TIMEOUT 30)

add_executable(sessionclipboard sessionclipboard.cxx)
target_link_libraries(sessionclipboard tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessionclipboard PROPERTIES TIMEOUT 30)

add_executable(sessionevents sessionevents.cxx)
target_link_libraries(sessionevents tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessionevents PROPERTIES TIMEOUT 30)

# MSVC builds run these against the MSYS2 GnuTLS DLLs; MinGW keeps excluding them.
if(GNUTLS_FOUND AND (NOT WIN32 OR MSVC))
  add_executable(certificatekey certificatekey.cxx)
  target_include_directories(certificatekey SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
  target_link_libraries(certificatekey tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(certificatekey PROPERTIES TIMEOUT 30)

  add_executable(clienttls clienttls.cxx)
  target_link_libraries(clienttls rfbclient GTest::gtest_main Threads::Threads)
  gtest_discover_tests(clienttls)

  if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux" OR MSVC)
    add_executable(authenticationsocket authenticationsocket.cxx)
    target_include_directories(authenticationsocket SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
    target_link_libraries(authenticationsocket tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
    gtest_discover_tests(authenticationsocket PROPERTIES TIMEOUT 30)
  endif()
endif()

add_executable(convertlf convertlf.cxx)
target_link_libraries(convertlf core GTest::gtest_main)
gtest_discover_tests(convertlf)

# Retained FLTK viewer sources: built with the MinGW/GCC/Clang toolchains
# only (the MSVC build serves the WinUI app).
if(NOT MSVC)
  add_executable(gesturehandler gesturehandler.cxx ../../vncviewer/GestureHandler.cxx)
  target_link_libraries(gesturehandler core GTest::gtest_main)
  gtest_discover_tests(gesturehandler)
endif()

add_executable(hostport hostport.cxx)
target_link_libraries(hostport network GTest::gtest_main)
gtest_discover_tests(hostport)

add_executable(endpoint endpoint.cxx)
target_link_libraries(endpoint tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(endpoint)

add_executable(encodingoptions encodingoptions.cxx)
target_link_libraries(encodingoptions tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(encodingoptions PROPERTIES TIMEOUT 30)

add_executable(sessionencoding sessionencoding.cxx)
target_link_libraries(sessionencoding tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessionencoding PROPERTIES TIMEOUT 30)

add_executable(sessionscheduler sessionscheduler.cxx)
target_link_libraries(sessionscheduler tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessionscheduler PROPERTIES TIMEOUT 30)

add_executable(sessionworker sessionworker.cxx)
target_link_libraries(sessionworker tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(sessionworker PROPERTIES TIMEOUT 30)

add_executable(listenerworker listenerworker.cxx)
target_link_libraries(listenerworker tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(listenerworker PROPERTIES TIMEOUT 30)

if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_executable(privatefilelogger privatefilelogger.cxx)
  target_link_libraries(privatefilelogger tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(privatefilelogger PROPERTIES TIMEOUT 30)
  add_executable(processloggingabi processloggingabi.cxx ../viewer/c-abi-test-support.cxx)
  target_link_libraries(processloggingabi tidyvnc_viewer_c tidyvnc_viewer_core Threads::Threads)
  add_test(NAME ProcessLoggingABI.InstallationAndOwnedStreams COMMAND processloggingabi configure)
  add_test(NAME ProcessLoggingABI.RuntimeClosesAdmission COMMAND processloggingabi freeze)
  set_tests_properties(ProcessLoggingABI.InstallationAndOwnedStreams ProcessLoggingABI.RuntimeClosesAdmission PROPERTIES TIMEOUT 30)
  find_package(Python3 QUIET COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    set(TIDYVNC_LOGGING_FIXTURE_OPTIONS)
    if(APPLE AND ENABLE_NLS)
      list(APPEND TIDYVNC_LOGGING_FIXTURE_OPTIONS --macos-unbundled-nls)
    endif()
    add_test(NAME ProcessLoggingABI.PrivateFileProcessOwnership
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/processlogging-file.py
        $<TARGET_FILE:processloggingabi> ${TIDYVNC_LOGGING_FIXTURE_OPTIONS})
    set_tests_properties(ProcessLoggingABI.PrivateFileProcessOwnership PROPERTIES TIMEOUT 45)
  endif()
  add_executable(socketlistener socketlistener.cxx)
  target_link_libraries(socketlistener tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(socketlistener PROPERTIES TIMEOUT 30)
  add_executable(socketconnector socketconnector.cxx)
  target_link_libraries(socketconnector tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(socketconnector PROPERTIES TIMEOUT 30)
  # Manual stalled-resolver check; built but intentionally not a CTest case.
  add_executable(stalledlookup stalledlookup.cxx)
  target_link_libraries(stalledlookup tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  add_executable(sessiontransport sessiontransport.cxx)
  target_link_libraries(sessiontransport tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(sessiontransport PROPERTIES TIMEOUT 30)
endif()

# Windows platform adapters (viewer/platform/windows, plans/native-ui-winui
# CORE.md section 5): the POSIX adapter contracts with Winsock fixtures.
if(WIN32 AND MSVC)
  foreach(name sessiontransport socketconnector privatefilelogger)
    add_executable(${name} windows/${name}.cxx)
    target_link_libraries(${name} tidyvnc_viewer_core GTest::gtest_main Threads::Threads ws2_32 advapi32)
    gtest_discover_tests(${name} DISCOVERY_TIMEOUT 30 PROPERTIES TIMEOUT 60)
  endforeach()
  if(GNUTLS_FOUND)
    add_executable(utf8paths windows/utf8paths.cxx windows/utf8.manifest)
    target_include_directories(utf8paths SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
    target_include_directories(utf8paths PRIVATE ${CMAKE_SOURCE_DIR}/common)
    target_link_libraries(utf8paths ${GNUTLS_LIBRARIES} GTest::gtest_main)
    gtest_discover_tests(utf8paths)
  endif()
  # The app manifest makes argv and narrow paths UTF-8 (utf8.manifest).
  add_executable(processloggingabi windows/processloggingabi.cxx ../viewer/c-abi-test-support.cxx windows/utf8.manifest)
  target_link_libraries(processloggingabi tidyvnc_viewer_c tidyvnc_viewer_core Threads::Threads)
  foreach(mode configure freeze default nostdio)
    add_test(NAME ProcessLoggingABI.Windows.${mode} COMMAND processloggingabi ${mode})
  endforeach()
  set_tests_properties(ProcessLoggingABI.Windows.configure ProcessLoggingABI.Windows.freeze
    ProcessLoggingABI.Windows.default ProcessLoggingABI.Windows.nostdio PROPERTIES TIMEOUT 30)
  find_package(Python3 QUIET COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME ProcessLoggingABI.Windows.PrivateFileProcessOwnership
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/windows/processlogging-file.py
        $<TARGET_FILE:processloggingabi>)
    set_tests_properties(ProcessLoggingABI.Windows.PrivateFileProcessOwnership PROPERTIES TIMEOUT 60)
  endif()
  add_executable(socketlistener socketlistener.cxx)
  target_link_libraries(socketlistener tidyvnc_viewer_core GTest::gtest_main Threads::Threads ws2_32)
  gtest_discover_tests(socketlistener PROPERTIES TIMEOUT 30)
  if(BUILD_WINUI_VIEWER)
    # The retained vncviewer/KeyboardWin32 against the helper DLL's extracted
    # translator, with a stub FL/Fl.H in place of FLTK (TODO W3.4).
    add_executable(keyboardtranslator windows/keyboardtranslator.cxx)
    target_include_directories(keyboardtranslator BEFORE PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/windows/fltk-stub
      ${CMAKE_SOURCE_DIR}/vncviewer)
    target_link_libraries(keyboardtranslator tidyvnc_windows_keyboard core GTest::gtest_main)
    gtest_discover_tests(keyboardtranslator PROPERTIES TIMEOUT 60)
    # The retained vncviewer/GestureHandler and BaseTouchHandler against the
    # helper's extracted TouchGestures on a scripted clock (TODO W6.7).
    add_executable(touchgestures windows/touchgestures.cxx)
    target_include_directories(touchgestures BEFORE PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/windows/touch-stub
      ${CMAKE_SOURCE_DIR}/vncviewer)
    target_link_libraries(touchgestures tidyvnc_windows_touch core GTest::gtest_main)
    gtest_discover_tests(touchgestures PROPERTIES TIMEOUT 60)
    add_executable(windowshelper windows/windowshelper.cxx)
    target_link_libraries(windowshelper tidyvnc_windows GTest::gtest_main)
    gtest_discover_tests(windowshelper PROPERTIES TIMEOUT 60)
  endif()
endif()

# C ABI sessions and listeners against loopback peers wherever the platform
# socket adapters exist (macOS, Linux, and Windows with MSVC).
if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux" OR MSVC)
  add_executable(viewerabi viewerabi.cxx ../viewer/c-abi-test-support.cxx)
  target_link_libraries(viewerabi tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(viewerabi DISCOVERY_TIMEOUT 30 PROPERTIES TIMEOUT 30)
  add_executable(listenerabi listenerabi.cxx ../viewer/c-abi-test-support.cxx)
  target_link_libraries(listenerabi tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
  gtest_discover_tests(listenerabi DISCOVERY_TIMEOUT 30 PROPERTIES TIMEOUT 30)
endif()

add_executable(nativeerrorcategory nativeerrorcategory.cxx)
target_link_libraries(nativeerrorcategory tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(nativeerrorcategory)

# Shared policy modules (plans/native-ui-winui CORE.md section 6) against the
# conformance corpus in tests/conformance, shared with the macOS Swift suite.
add_executable(identitydigest identitydigest.cxx)
target_compile_definitions(identitydigest PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(identitydigest tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(identitydigest)
add_executable(legacyknownhosts legacyknownhosts.cxx)
target_compile_definitions(legacyknownhosts PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(legacyknownhosts tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
if(GNUTLS_FOUND AND (NOT WIN32 OR MSVC))
  # Cross-check against files GnuTLS itself writes (the retained viewer's store).
  target_compile_definitions(legacyknownhosts PRIVATE TIDYVNC_KNOWN_HOSTS_GNUTLS)
  target_include_directories(legacyknownhosts SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
  target_link_libraries(legacyknownhosts ${GNUTLS_LIBRARIES})
endif()
gtest_discover_tests(legacyknownhosts)
add_executable(legacymonitornumbering legacymonitornumbering.cxx)
target_compile_definitions(legacymonitornumbering PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(legacymonitornumbering tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(legacymonitornumbering)
add_executable(exportloss exportloss.cxx)
target_compile_definitions(exportloss PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(exportloss tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(exportloss)
add_executable(importprojection importprojection.cxx)
target_compile_definitions(importprojection PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(importprojection tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(importprojection)
add_executable(configurationlayers configurationlayers.cxx)
target_compile_definitions(configurationlayers PRIVATE TIDYVNC_CONFORMANCE_DIR="${CMAKE_SOURCE_DIR}/tests/conformance")
target_link_libraries(configurationlayers tidyvnc_viewer_c tidyvnc_viewer_core GTest::gtest_main Threads::Threads)
gtest_discover_tests(configurationlayers)

add_executable(parameters parameters.cxx)
target_link_libraries(parameters core GTest::gtest_main)
gtest_discover_tests(parameters)

add_executable(pixelformat pixelformat.cxx)
target_link_libraries(pixelformat rfb GTest::gtest_main)
gtest_discover_tests(pixelformat)

# Retained FLTK viewer sources: built with the MinGW/GCC/Clang toolchains
# only (the MSVC build serves the WinUI app).
if(NOT MSVC)
  add_executable(shortcuthandler shortcuthandler.cxx ../../vncviewer/ShortcutHandler.cxx)
  target_link_libraries(shortcuthandler tidyvnc_viewer_core ${Intl_LIBRARIES} GTest::gtest_main)
  gtest_discover_tests(shortcuthandler)
endif()

add_executable(unicode unicode.cxx)
target_link_libraries(unicode core GTest::gtest_main)
gtest_discover_tests(unicode)

# Retained FLTK viewer sources: built with the MinGW/GCC/Clang toolchains
# only (the MSVC build serves the WinUI app).
if(NOT MSVC)
  add_executable(emulatemb emulatemb.cxx ../../vncviewer/EmulateMB.cxx)
  target_link_libraries(emulatemb tidyvnc_viewer_core GTest::gtest_main)
  gtest_discover_tests(emulatemb)
endif()

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
if(BUILD_FLTK_VIEWER AND (APPLE OR WIN32))
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

if(BUILD_FLTK_VIEWER AND NOT WIN32)
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

add_executable(frametilerenderer frametilerenderer.cxx ../viewer/c-abi-test-support.cxx)
target_link_libraries(frametilerenderer tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(frametilerenderer)

add_executable(securityoptions securityoptions.cxx)
target_link_libraries(securityoptions tidyvnc_viewer_core GTest::gtest_main)
gtest_discover_tests(securityoptions)
