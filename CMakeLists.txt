#
# Setup
#

cmake_minimum_required(VERSION 3.15)

# Internal cmake modules
set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake/Modules)

include(CheckIncludeFiles)
include(CheckFunctionExists)
include(CheckLibraryExists)
include(CheckVariableExists)
include(CheckTypeSize)
include(CheckCSourceCompiles)
include(CheckCXXSourceCompiles)
include(CheckCSourceRuns)

include(CMakeMacroLibtoolFile)

project(tidyvnc)
set(VERSION 1.16.80)

# The RC version must always be four comma-separated numbers
string(REPLACE . , RCVERSION "${VERSION}.0")

# Installation paths
include(GNUInstallDirs)
set(CMAKE_INSTALL_UNITDIR "lib/systemd/system" CACHE PATH "systemd unit files (lib/systemd/system)")
if(IS_ABSOLUTE "${CMAKE_INSTALL_UNITDIR}")
  set(CMAKE_INSTALL_FULL_UNITDIR "${CMAKE_INSTALL_UNITDIR}")
else()
  set(CMAKE_INSTALL_FULL_UNITDIR "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_UNITDIR}")
endif()

option(INSTALL_SYSTEMD_UNITS "Install TigerVNC systemd units" ON)


if(NOT BUILD_TIMESTAMP)
  STRING(TIMESTAMP BUILD_TIMESTAMP "%Y-%m-%d %H:%M" UTC)
endif()

# Default to optimised builds instead of debug ones. Our code has no bugs ;)
# (CMake makes it fairly easy to toggle this back to Debug if needed)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

message(STATUS "CMAKE_BUILD_TYPE = ${CMAKE_BUILD_TYPE}")

message(STATUS "VERSION = ${VERSION}")
message(STATUS "BUILD_TIMESTAMP = ${BUILD_TIMESTAMP}")

if(MSVC)
  # MSVC (and clang-cl) builds only the portable core, the C ABI DLL and the
  # WinUI frontend's native parts; see plans/native-ui-winui/CORE.md section 2. MSVC
  # has no C++11 mode, so the code is compiled as C++17 here while GCC and
  # Clang keep checking C++11.
  foreach(flags CMAKE_C_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELEASE
                CMAKE_C_FLAGS_RELWITHDEBINFO CMAKE_CXX_FLAGS_RELWITHDEBINFO
                CMAKE_C_FLAGS_MINSIZEREL CMAKE_CXX_FLAGS_MINSIZEREL)
    string(REPLACE "/DNDEBUG" "" ${flags} "${${flags}}")
    set(${flags} "${${flags}} /UNDEBUG")
  endforeach()
  set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} /D_DEBUG")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /D_DEBUG")
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /std:c11 /utf-8 /W4")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++17 /utf-8 /W4 /EHsc /permissive- /Zc:__cplusplus")
  include(cmake/MSVCWarnings.cmake)
  # POSIX spellings for the shared sources (common/compat/msvc).
  include_directories(BEFORE SYSTEM ${CMAKE_SOURCE_DIR}/common/compat/msvc)
  add_compile_options("/FI${CMAKE_SOURCE_DIR}/common/compat/msvc/tidyvnc_msvc_compat.h")
  add_compile_options(/guard:cf)
  add_link_options(/guard:cf)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64|x64" AND NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    add_link_options(/CETCOMPAT)
  endif()
  # The shared sources call the ANSI Win32 entry points as the MinGW build
  # does, so UNICODE/_UNICODE are set only on the Windows-only targets
  # (viewer/platform/windows, platform/windows), which use W APIs explicitly.
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN _USE_MATH_DEFINES
                          _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_WARNINGS
                          _WINSOCK_DEPRECATED_NO_WARNINGS)
  option(TIDYVNC_MSVC_WERROR "Treat MSVC warnings as errors in Debug builds" ON)
  if(TIDYVNC_MSVC_WERROR)
    set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} /WX")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /WX")
  endif()
else()
  # We want to keep our asserts even in release builds so remove NDEBUG
  set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -UNDEBUG")
  set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -UNDEBUG")
  set(CMAKE_C_FLAGS_RELWITHDEBINFO "${CMAKE_C_FLAGS_RELWITHDEBINFO} -UNDEBUG")
  set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "${CMAKE_CXX_FLAGS_RELWITHDEBINFO} -UNDEBUG")
  set(CMAKE_C_FLAGS_MINSIZEREL "${CMAKE_C_FLAGS_MINSIZEREL} -UNDEBUG")
  set(CMAKE_CXX_FLAGS_MINSIZEREL "${CMAKE_CXX_FLAGS_MINSIZEREL} -UNDEBUG")

  # But extra debug checks are still gated by this custom define
  set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -D_DEBUG")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -D_DEBUG")

  # Enable debug friendly optimizations for debug builds
  set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -Og")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -Og")

  # Make sure we get a sane C and C++ version
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -std=gnu99")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=gnu++11")

  # Tell the compiler to be stringent
  add_compile_definitions(_FORTIFY_SOURCE=2)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -Wextra -Wformat=2 -Wvla")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wformat=2 -Wvla")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wzero-as-null-pointer-constant")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wsuggest-override")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wshadow")
  # Make sure we catch these issues whilst developing
  set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -Werror")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -Werror")
  # clang doesn't support format_arg, which breaks this warning
  if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-format-nonliteral -Wno-format-security")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-format-nonliteral -Wno-format-security")
  endif()
endif()

option(ENABLE_ASAN "Enable address sanitizer support" OFF)
if(ENABLE_ASAN AND MSVC)
  # /fsanitize=address is incompatible with /guard:cf's runtime checks in
  # the same image only for incremental linking; keep both, link fully.
  add_compile_options(/fsanitize=address /Zi)
  add_link_options(/INCREMENTAL:NO /DEBUG)
elseif(ENABLE_ASAN AND NOT WIN32 AND NOT APPLE)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fsanitize=address")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address")
endif()

option(ENABLE_TSAN "Enable thread sanitizer support" OFF)
if(ENABLE_TSAN AND NOT WIN32 AND NOT APPLE AND CMAKE_SIZEOF_VOID_P MATCHES 8)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fsanitize=thread")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=thread")
endif()

if(NOT DEFINED BUILD_WINVNC)
  set(BUILD_WINVNC 1)
endif()

# Minimum version is Windows 7 for the MinGW (FLTK and server) builds. MSVC
# builds serve the WinUI app, which supports Windows 11 only (D6); 0x0A00 is
# the value that covers Windows 10 and 11.
if(MSVC)
  add_definitions(-D_WIN32_WINNT=0x0A00)
elseif(WIN32)
  add_definitions(-D_WIN32_WINNT=0x0601)
endif()

# Legacy macros (macOS 10.12 and older) conflict with our code
if(APPLE)
  add_definitions(-D__ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES=0)
endif()

#### Check for required and optional libraries ####

macro(trioption VAR DESC)
  set(${VAR} AUTO CACHE STRING "${DESC}")
  set_property(CACHE ${VAR} PROPERTY STRINGS AUTO ON OFF)
endmacro()

trioption(BUILD_VIEWER "Build TidyVNC viewer")
option(BUILD_PLATFORM_APPS "Build platform servers and configuration tools" ON)
option(BUILD_MACOS_NATIVE "Build the experimental macOS Swift bridge and its tests" OFF)
include(cmake/ViewerFrontend.cmake)
if(MSVC)
  # The FLTK viewer and the Windows server still require MinGW; MSVC builds
  # the headless core and the WinUI frontend's native parts only.
  if(BUILD_FLTK_VIEWER)
    message(FATAL_ERROR "The FLTK viewer must be built with MinGW; use -DTIDYVNC_UI=WINUI or -DBUILD_VIEWER=OFF with MSVC")
  endif()
  if(BUILD_PLATFORM_APPS)
    message(FATAL_ERROR "The Windows server must be built with MinGW; use -DBUILD_PLATFORM_APPS=OFF with MSVC")
  endif()
endif()
if(BUILD_SWIFTUI_VIEWER)
  include(cmake/NativeAppPrerequisites.cmake)
endif()
if(BUILD_MACOS_NATIVE)
  if(NOT APPLE)
    message(FATAL_ERROR "BUILD_MACOS_NATIVE requires macOS and a Swift 6 toolchain")
  endif()
  if(CMAKE_VERSION VERSION_LESS 3.29)
    message(FATAL_ERROR "BUILD_MACOS_NATIVE requires CMake 3.29 or later for explicit Swift compilation modes")
  endif()
  cmake_policy(SET CMP0157 NEW)
  # Swift 6.4's incremental executable rebuild can reference a removed temporary
  # module after an imported module changes. Compile these small native modules
  # as a whole; retain normal Debug/Release optimization and debug-info settings.
  set(CMAKE_Swift_COMPILATION_MODE wholemodule)
  # Compiler probes must also keep generated Clang/Swift modules in the build
  # tree, including when the user's home cache is unavailable in a sandbox.
  if(NOT DEFINED ENV{CLANG_MODULE_CACHE_PATH})
    set(ENV{CLANG_MODULE_CACHE_PATH} "${CMAKE_BINARY_DIR}/swift-module-cache")
  endif()
  include(CheckLanguage)
  check_language(Swift)
  if(NOT CMAKE_Swift_COMPILER)
    message(FATAL_ERROR "BUILD_MACOS_NATIVE requires a Swift 6 toolchain (use the selected Xcode or command-line tools)")
  endif()
  enable_language(Swift)
  if(CMAKE_Swift_COMPILER_VERSION VERSION_LESS 6.0)
    message(FATAL_ERROR "BUILD_MACOS_NATIVE requires Swift 6 or later")
  endif()
endif()

# X11 stuff. It's in a if() so that we can say REQUIRED
if(UNIX AND NOT APPLE AND (BUILD_FLTK_VIEWER OR BUILD_PLATFORM_APPS))
  find_package(X11 REQUIRED)
  if(X11_Xdamage_LIB)
    set(HAVE_XDAMAGE 1)
  endif()
  if(X11_Xfixes_LIB)
    set(HAVE_XFIXES 1)
  endif()
  if(X11_Xrandr_LIB)
    set(HAVE_XRANDR 1)
  endif()
  if(X11_XTest_LIB)
    set(HAVE_XTEST 1)
  endif()
endif()

# Check for zlib
find_package(ZLIB REQUIRED)

# Check for pixman
find_package(Pixman REQUIRED)

# Check for gettext
trioption(ENABLE_NLS "Enable translation of program messages")
if(ENABLE_NLS)
  # Tools
  if(ENABLE_NLS STREQUAL "AUTO")
    find_package(Gettext)
  else()
    find_package(Gettext REQUIRED)
  endif()

  # Runtime library
  if(ENABLE_NLS STREQUAL "AUTO")
    find_package(Intl)
  else()
    find_package(Intl REQUIRED)
  endif()

  if(NOT GETTEXT_FOUND OR NOT INTL_FOUND)
    message(WARNING "Gettext NOT found.  Native Language Support disabled.")
    set(ENABLE_NLS 0)
  endif()
endif()

trioption(ENABLE_H264 "Enable H.264 RFB encoding")
if(ENABLE_H264)
  if(WIN32)
    set(HAVE_H264 1)

    set(CMAKE_REQUIRED_LIBRARIES ole32 mfplat mfuuid wmcodecdspuuid)
    check_variable_exists(CLSID_VideoProcessorMFT HAVE_VIDEO_PROCESSOR_MFT)
    set(CMAKE_REQUIRED_LIBRARIES)
  else()
    if(ENABLE_H264 STREQUAL "AUTO")
      find_package(AVCodec)
      find_package(AVUtil)
      find_package(SWScale)
    else()
      find_package(AVCodec REQUIRED)
      find_package(AVUtil REQUIRED)
      find_package(SWScale REQUIRED)
    endif()
    if (AVCODEC_FOUND AND AVUTIL_FOUND AND SWSCALE_FOUND)
      set(HAVE_H264 1)
      set(HAVE_LIBAV 1)
    else()
      message(WARNING "FFMPEG support can't be found")
    endif()
  endif()
endif()

trioption(ENABLE_AUDIO "Enable audio playback in the viewer")
if(ENABLE_AUDIO AND BUILD_VIEWER)
  if(WIN32)
    # waveOut comes with the OS
    set(HAVE_AUDIO 1)
  elseif(APPLE)
    if(ENABLE_AUDIO STREQUAL "AUTO")
      message(WARNING "Audio playback is not supported on macOS")
    else()
      message(FATAL_ERROR "Audio playback is not supported on macOS")
    endif()
  else()
    if(ENABLE_AUDIO STREQUAL "AUTO")
      find_package(Pulse)
    else()
      find_package(Pulse REQUIRED)
    endif()
    if(PULSE_FOUND)
      set(HAVE_AUDIO 1)
    else()
      message(WARNING "PulseAudio NOT found. Audio playback disabled.")
    endif()
  endif()
endif()

# Check for libjpeg
find_package(JPEG REQUIRED)

# Warn if it doesn't seem to be the accelerated libjpeg that's found
set(CMAKE_REQUIRED_LIBRARIES ${JPEG_LIBRARIES})
set(CMAKE_REQUIRED_FLAGS -I${JPEG_INCLUDE_DIR})

set(JPEG_TEST_SOURCE "\n
  #include <stdio.h>\n
  #include <jpeglib.h>\n
  int main(void) {\n
    struct jpeg_compress_struct cinfo;\n
    struct jpeg_error_mgr jerr;\n
    cinfo.err=jpeg_std_error(&jerr);\n
    jpeg_create_compress(&cinfo);\n
    cinfo.input_components = 3;\n
    jpeg_set_defaults(&cinfo);\n
    cinfo.in_color_space = JCS_EXT_RGB;\n
    jpeg_default_colorspace(&cinfo);\n
    return 0;\n
  }")

if(CMAKE_CROSSCOMPILING)
  check_c_source_compiles("${JPEG_TEST_SOURCE}" FOUND_LIBJPEG_TURBO)
else()
  check_c_source_runs("${JPEG_TEST_SOURCE}" FOUND_LIBJPEG_TURBO)
endif()

set(CMAKE_REQUIRED_LIBRARIES)
set(CMAKE_REQUIRED_FLAGS)
set(CMAKE_REQUIRED_DEFINITIONS)

if(NOT FOUND_LIBJPEG_TURBO)
  message(STATUS "Warning: You are not using libjpeg-turbo. Performance will suffer.")
endif()

if(BUILD_FLTK_VIEWER)
  # FLTK 1.4 provides DPI-aware layout and public native-platform accessors.
  # Use its exported targets; FindFLTK's 1.3 variables lose transitive links.
  include(cmake/BrandingOptions.cmake)
  if(BUILD_VIEWER STREQUAL "AUTO")
    find_package(FLTK 1.4.5 CONFIG QUIET)
  else()
    find_package(FLTK 1.4.5 CONFIG REQUIRED)
  endif()
  if(NOT FLTK_FOUND)
    message(WARNING "FLTK 1.4.5 not found; viewer disabled (set FLTK_DIR)")
    set(BUILD_VIEWER 0)
    set(BUILD_FLTK_VIEWER OFF)
  else()
    if(NOT FLTK_VERSION VERSION_LESS 1.5)
      message(FATAL_ERROR "The viewer requires the tested FLTK 1.4 series")
    endif()
    if(TIDYVNC_FLTK_SHARED)
      if(BUILD_STATIC)
        message(FATAL_ERROR "BUILD_STATIC requires static FLTK")
      endif()
      set(TIDYVNC_FLTK_TARGET fltk::images-shared)
    else()
      set(TIDYVNC_FLTK_TARGET fltk::images)
    endif()
    if(NOT TARGET ${TIDYVNC_FLTK_TARGET})
      message(FATAL_ERROR "FLTK package does not provide ${TIDYVNC_FLTK_TARGET}")
    endif()
    message(STATUS "Viewer FLTK ${FLTK_VERSION}: ${TIDYVNC_FLTK_TARGET} (${FLTK_DIR})")
  endif()
endif()

# Check for GNUTLS library
trioption(ENABLE_GNUTLS "Enable protocol encryption and advanced authentication")
if(ENABLE_GNUTLS)
  if(ENABLE_GNUTLS STREQUAL "AUTO")
    find_package(GnuTLS)
  else()
    find_package(GnuTLS REQUIRED)
  endif()
  if (GNUTLS_FOUND)
    set(HAVE_GNUTLS 1)
  endif()
endif()

trioption(ENABLE_NETTLE "Enable RSA-AES security types")
if (ENABLE_NETTLE)
  if(ENABLE_NETTLE STREQUAL "AUTO")
    find_package(Nettle)
  else()
    find_package(Nettle REQUIRED)
  endif()
  if (NETTLE_FOUND)
    set(HAVE_NETTLE 1)
  endif()
endif()

# Check for PAM library
if(UNIX AND NOT APPLE AND BUILD_PLATFORM_APPS)
  trioption(ENABLE_PAM "Enable authentication using PAM")
  if(ENABLE_PAM)
    if(ENABLE_PAM STREQUAL "AUTO")
      find_package(PAM)
    else()
      find_package(PAM REQUIRED)
    endif()
    if(PAM_FOUND)
      set(HAVE_PAM 1)
    else()
      message(WARNING "PAM NOT found. vncserver and PAM authentication disabled.")
    endif()
  endif()
endif()

# Check for SELinux library
if(UNIX AND NOT APPLE AND BUILD_PLATFORM_APPS)
  trioption(ENABLE_SELINUX "Enable SELinux support")
  if(ENABLE_SELINUX)
    if(ENABLE_SELINUX STREQUAL "AUTO")
      find_package(SELinux)
    else()
      find_package(SELinux REQUIRED)
    endif()
    if(SELINUX_FOUND)
      set(HAVE_SELINUX 1)
    endif()
  endif()
endif()

# check for systemd support (socket activation)
if(UNIX AND NOT APPLE AND BUILD_PLATFORM_APPS)
  trioption(ENABLE_SYSTEMD "Enable systemd support")
  if(ENABLE_SYSTEMD)
    if(ENABLE_SYSTEMD STREQUAL "AUTO")
      find_package(Systemd)
    else()
      find_package(Systemd REQUIRED)
    endif()
    if (SYSTEMD_FOUND)
      set(HAVE_LIBSYSTEMD 1)
    endif()
  endif()
endif()

# check for password pwquality check support
if(UNIX AND NOT APPLE AND BUILD_PLATFORM_APPS)
  trioption(ENABLE_PWQUALITY "Enable password pwquality check")
  if(ENABLE_PWQUALITY)
    if(ENABLE_PWQUALITY STREQUAL "AUTO")
      find_package(PWQuality)
    else()
      find_package(PWQuality REQUIRED)
    endif()
    if(PWQUALITY_FOUND)
      set(HAVE_PWQUALITY 1)
    endif()
  endif()
endif()

# check for libraries needed for wayland support
if(UNIX AND NOT APPLE AND BUILD_PLATFORM_APPS)
  trioption(ENABLE_WAYLAND "Enable wayland support")
  if(ENABLE_WAYLAND)
    if(ENABLE_WAYLAND STREQUAL "AUTO")
      find_package(GLib)
      find_package(Gio)
      find_package(Gobject)

      # Portals specific
      find_package(PipeWire)
      find_package(Uuid)

      # wlroots specific
      find_package(WaylandClient)
      find_package(Xkbcommon)
    else()
      find_package(GLib REQUIRED)
      find_package(Gio REQUIRED)
      find_package(Gobject REQUIRED)

      # Portals specific
      find_package(PipeWire REQUIRED)
      find_package(Uuid REQUIRED)

      # wlroots specific
      find_package(WaylandClient REQUIRED)
      find_package(Xkbcommon REQUIRED)
    endif()
    if(NOT GLIB_FOUND OR NOT GIO_FOUND OR NOT GOBJECT_FOUND OR NOT PIPEWIRE_FOUND
       OR NOT UUID_FOUND OR NOT WAYLANDCLIENT_FOUND OR NOT XKBCOMMON_FOUND)
      set(ENABLE_WAYLAND 0)
      message(WARNING "GLib, Gio, Gobject, PipeWire, Uuid, WaylandClient or Xkbcommon NOT found. w0vncserver disabled.")
    endif()
  endif()
endif()

# Production libraries and the top-level libtool dependency walk both consume
# this imported target. Do not rely on optional GTest discovery to make it
# visible outside common/core and common/network's directory scopes.
find_package(Threads REQUIRED)
find_package(GTest)

# Generate config.h and make sure the source finds it
configure_file(config.h.in config.h)
add_definitions(-DHAVE_CONFIG_H)
include_directories(${CMAKE_BINARY_DIR})

include(cmake/StaticBuild.cmake)
if(MSVC)
  include(cmake/WindowsRuntime.cmake)
endif()

add_subdirectory(common)
add_subdirectory(viewer)
if(BUILD_MACOS_NATIVE)
  add_subdirectory(platform/macos)
endif()
if(BUILD_WINUI_VIEWER)
  add_subdirectory(platform/windows/Native)
endif()

if(BUILD_PLATFORM_APPS)
  if(WIN32)
    add_subdirectory(win)
  elseif(NOT APPLE)
    # No interest in building x related parts on Apple
    add_subdirectory(unix)
  endif()
endif()

if(ENABLE_NLS)
  add_subdirectory(po)
endif()

if(BUILD_FLTK_VIEWER)
  add_subdirectory(vncviewer)
  add_subdirectory(media)
elseif(BUILD_SWIFTUI_VIEWER)
  include(cmake/NativeApp.cmake)
endif()

add_subdirectory(tests)


if(BUILD_FLTK_VIEWER)
  add_subdirectory(release)
endif()

# uninstall
configure_file("${CMAKE_SOURCE_DIR}/cmake/cmake_uninstall.cmake.in"
  "cmake_uninstall.cmake" IMMEDIATE @ONLY)

add_custom_target(uninstall COMMAND ${CMAKE_COMMAND} -P cmake_uninstall.cmake)

libtool_generate_control_files()
