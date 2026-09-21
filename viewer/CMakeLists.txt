# Dependency direction: frontend -> viewer_core -> viewer_platform / RFB.
add_library(tidyvnc_viewer_platform STATIC platform/DisplayMetrics.cxx)
target_include_directories(tidyvnc_viewer_platform PUBLIC ${CMAKE_SOURCE_DIR})
if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_sources(tidyvnc_viewer_platform PRIVATE platform/SocketTransport.cxx platform/SocketConnector.cxx platform/SocketListener.cxx platform/PrivateFileLogger.cxx)
  target_link_libraries(tidyvnc_viewer_platform PUBLIC network)
endif()
if(APPLE)
  # DNS-SD is re-exported by libSystem on macOS, not a separate libdns_sd.
  include(CheckSymbolExists)
  check_symbol_exists(DNSServiceGetAddrInfo "dns_sd.h" TIDYVNC_HAVE_ASYNC_DNS)
  if(NOT TIDYVNC_HAVE_ASYNC_DNS)
    message(FATAL_ERROR "The macOS asynchronous system resolver API was not found")
  endif()
endif()

add_library(tidyvnc_viewer_core STATIC
  core/Invocation.cxx
  core/LoggingPolicy.cxx
  core/RedactedLogger.cxx
  core/StartupLogging.cxx
  core/WindowGeometry.cxx
  core/ConnectionDocument.cxx
  core/DocumentOptions.cxx
  core/Endpoint.cxx
  core/EncodingOptions.cxx
  core/SecurityOptions.cxx
  core/FramePublisher.cxx
  core/ProtocolSession.cxx
  core/CertificateKey.cxx
  core/CertificatePolicy.cxx
  core/PromptAuthentication.cxx
  core/InputQueue.cxx
  core/MiddleButtonEmulator.cxx
  core/ShortcutState.cxx
  core/SessionEvents.cxx
  core/SessionScheduler.cxx
  core/SessionWorker.cxx
  core/RemoteDesktopLayout.cxx
  core/ClipboardChannel.cxx
  core/ListenerWorker.cxx
  core/DesktopTransform.cxx
  core/DesktopLayout.cxx
  core/DesktopResampler.cxx
  core/FrameTileRenderer.cxx
  core/DesktopTileCache.cxx
  core/CursorRenderer.cxx)
target_include_directories(tidyvnc_viewer_core PUBLIC ${CMAKE_SOURCE_DIR})
target_link_libraries(tidyvnc_viewer_core PUBLIC
  tidyvnc_viewer_platform rfbclient network)

add_library(tidyvnc_viewer_c STATIC bridge/tidyvnc.cxx)
target_include_directories(tidyvnc_viewer_c PUBLIC ${CMAKE_SOURCE_DIR}/viewer/bridge)
target_link_libraries(tidyvnc_viewer_c PRIVATE tidyvnc_viewer_core)
