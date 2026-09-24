# Dependency direction: frontend -> viewer_core -> viewer_platform / RFB.
add_library(tidyvnc_viewer_platform STATIC platform/DisplayMetrics.cxx platform/NativeErrorCategory.cxx)
target_include_directories(tidyvnc_viewer_platform PUBLIC ${CMAKE_SOURCE_DIR})
if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_sources(tidyvnc_viewer_platform PRIVATE platform/SocketTransport.cxx platform/SocketConnector.cxx platform/SocketListener.cxx platform/PrivateFileLogger.cxx)
  target_link_libraries(tidyvnc_viewer_platform PUBLIC network)
  target_compile_definitions(tidyvnc_viewer_platform PUBLIC TIDYVNC_PLATFORM_SOCKETS)
elseif(WIN32 AND MSVC)
  # Winsock/Win32 adapters for the WinUI app (plans/native-ui-winui/CORE.md
  # section 5). The MinGW FLTK build keeps its own networking and does not
  # compile them.
  target_sources(tidyvnc_viewer_platform PRIVATE
    platform/windows/SocketTransport.cxx platform/windows/SocketConnector.cxx
    platform/windows/SocketListener.cxx platform/windows/PrivateFileLogger.cxx)
  target_link_libraries(tidyvnc_viewer_platform PUBLIC network PRIVATE ws2_32 iphlpapi advapi32)
  target_compile_definitions(tidyvnc_viewer_platform PUBLIC TIDYVNC_PLATFORM_SOCKETS)
endif()
if(APPLE)
  # DNS-SD is re-exported by libSystem on macOS, not a separate libdns_sd.
  include(CheckSymbolExists)
  check_symbol_exists(DNSServiceGetAddrInfo "dns_sd.h" TIDYVNC_HAVE_ASYNC_DNS)
  if(NOT TIDYVNC_HAVE_ASYNC_DNS)
    message(FATAL_ERROR "The macOS asynchronous system resolver API was not found")
  endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # glibc's cancellable asynchronous lookup: libc since 2.34, libanl before.
  # Without it (for example musl), hostnames are reported as unsupported.
  include(CheckSymbolExists)
  include(CMakePushCheckState)
  cmake_push_check_state(RESET)
  set(CMAKE_REQUIRED_DEFINITIONS -D_GNU_SOURCE)
  check_symbol_exists(getaddrinfo_a "netdb.h" TIDYVNC_HAVE_LIBC_GETADDRINFO_A)
  if(NOT TIDYVNC_HAVE_LIBC_GETADDRINFO_A)
    set(CMAKE_REQUIRED_LIBRARIES anl)
    check_symbol_exists(getaddrinfo_a "netdb.h" TIDYVNC_HAVE_LIBANL_GETADDRINFO_A)
  endif()
  cmake_pop_check_state()
  if(TIDYVNC_HAVE_LIBC_GETADDRINFO_A OR TIDYVNC_HAVE_LIBANL_GETADDRINFO_A)
    target_compile_definitions(tidyvnc_viewer_platform PRIVATE TIDYVNC_HAVE_GETADDRINFO_A)
    if(TIDYVNC_HAVE_LIBANL_GETADDRINFO_A)
      target_link_libraries(tidyvnc_viewer_platform PRIVATE anl)
    endif()
  else()
    message(STATUS "No cancellable resolver: native session hostnames are unsupported")
  endif()
endif()

add_library(tidyvnc_viewer_core STATIC
  core/Invocation.cxx
  core/LoggingPolicy.cxx
  core/RedactedLogger.cxx
  core/StartupLogging.cxx
  core/WindowGeometry.cxx
  core/DesktopSize.cxx
  core/SSHGateway.cxx
  core/IdentityDigest.cxx
  core/LegacyKnownHosts.cxx
  core/LegacyMonitorNumbering.cxx
  core/ExportLoss.cxx
  core/ImportProjection.cxx
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
target_compile_definitions(tidyvnc_viewer_c PUBLIC TIDYVNC_STATIC)
target_link_libraries(tidyvnc_viewer_c PRIVATE tidyvnc_viewer_core)

# The WinUI app loads the core and C ABI as one DLL exporting exactly the
# tidyvnc_* functions (plans/native-ui-winui/CORE.md section 4).
if(WIN32 AND MSVC)
  add_library(tidyvnc_viewer_shared SHARED bridge/tidyvnc.cxx)
  set_target_properties(tidyvnc_viewer_shared PROPERTIES OUTPUT_NAME tidyvnc_viewer)
  target_include_directories(tidyvnc_viewer_shared PUBLIC ${CMAKE_SOURCE_DIR}/viewer/bridge)
  target_compile_definitions(tidyvnc_viewer_shared PRIVATE TIDYVNC_BUILDING_DLL)
  target_link_libraries(tidyvnc_viewer_shared PRIVATE tidyvnc_viewer_core)
endif()
