# Native-only dependency direction: Swift -> C ABI -> portable viewer core.
# Remove inherited C preprocessor definitions from the Swift compilation.
set_directory_properties(PROPERTIES COMPILE_DEFINITIONS "")
add_library(tidyvnc_macos_keymap STATIC KeyMap/NativeKeyMap.c KeyMap/NativeKeyboardCapture.c
  ../../vncviewer/keysym2ucs.c ../../vncviewer/osx_to_qnum.c)
target_link_libraries(tidyvnc_macos_keymap PUBLIC "-framework Carbon" "-framework ApplicationServices")
target_include_directories(tidyvnc_macos_keymap PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/KeyMap PRIVATE ${CMAKE_SOURCE_DIR}/common)
add_library(tidyvnc_macos_askpass STATIC Tunnel/Askpass/NativeAskpass.c)
target_include_directories(tidyvnc_macos_askpass PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Tunnel/Askpass)
target_link_libraries(tidyvnc_macos_askpass PUBLIC Threads::Threads)
add_executable(tidyvnc-ssh-askpass Tunnel/Askpass/main.c)
target_link_libraries(tidyvnc-ssh-askpass PRIVATE tidyvnc_macos_askpass)
configure_file(Bridge/NativeBuildInfo.swift.in ${CMAKE_CURRENT_BINARY_DIR}/NativeBuildInfo.swift @ONLY)
add_library(tidyvnc_macos_bridge STATIC
  ${CMAKE_CURRENT_BINARY_DIR}/NativeBuildInfo.swift
  Settings/NativeInvocationBootstrap.swift
  Settings/NativeInvocationMonitorMapping.swift
  Bridge/NativeInvocation.swift
  Bridge/NativeProcessLogging.swift
  Bridge/NativeConnectionDocument.swift
  Settings/NativeDocumentResolution.swift
  Settings/NativeFullscreenOptions.swift
  Settings/NativeOptionOverlay.swift
  Settings/NativeInvocationResolution.swift
  Settings/NativeWindowStartupPolicy.swift
  Desktop/NativeWindowStartupState.swift
  Settings/NativeNetworkPolicy.swift
  Settings/NativeDefaultsImport.swift
  Settings/NativeDefaultsImportMapping.swift
  Settings/NativeHistoryImport.swift
  Settings/NativeDefaultsImportState.swift
  Settings/NativeHistoryImportState.swift
  Settings/NativeDocumentMonitorMapping.swift
  Settings/NativeDocumentExport.swift
  Settings/NativeDocumentExportCapture.swift
  Settings/NativeDocumentSaveState.swift
  Bridge/NativeRemoteLayout.swift
  Bridge/NativeValues.swift
  Bridge/NativeTrust.swift
  Bridge/NativeConnectionIssue.swift
  Presentation/NativePresentationIssue.swift
  Presentation/NativeBell.swift
  Presentation/NativeStatusColors.swift
  Bridge/NativeDelivery.swift
  Bridge/NativeRuntime.swift
  Tunnel/NativeTunnelProcess.swift
  Tunnel/NativeTunnelOutput.swift
  Tunnel/NativeSSHConfiguration.swift
  Tunnel/NativeSSHConfigurationSnapshot.swift
  Tunnel/NativeSSHTunnel.swift
  Tunnel/NativeSSHAskpass.swift
  Tunnel/NativeSSHInteraction.swift
  Tunnel/NativeSSHHostKey.swift
  Bridge/NativeListener.swift
  Bridge/NativeSession.swift
  Bridge/NativePointerTiming.swift
  Bridge/NativeMessageLimits.swift
  Bridge/NativeClipboard.swift
  Bridge/NativeEncoding.swift
  Bridge/NativeSecurity.swift
  Storage/NativeSecurityPreferences.swift
  Bridge/NativeShortcuts.swift
  Bridge/NativeEndpoint.swift
  Clipboard/NativePasteboard.swift
  Clipboard/NativeClipboardCoordinator.swift
  Display/NativeDisplayService.swift
  Display/NativeDisplayLayout.swift
  Storage/NativePreferencesStore.swift
  Storage/NativePreferencesModels.swift
  Storage/NativeDocumentWriter.swift
  Storage/NativeDocumentFile.swift
  Storage/NativeImportSources.swift
  Storage/NativeHistoryImportService.swift
  Storage/NativeDocumentLaunch.swift
  Storage/NativeEncodingPreferences.swift
  Storage/NativeInputPreferences.swift
  Storage/NativeScalingPreferences.swift
  Storage/NativeRemoteResizePreferences.swift
  Storage/NativeTrustFiles.swift
  Storage/NativePrivateFile.swift
  Storage/NativeLegacyTrustStore.swift
  Storage/NativeTrustStore.swift
  Storage/NativeTrustLibrary.swift
  Storage/NativeCertificateTrust.swift
  Storage/NativeCredentialKey.swift
  Storage/NativeAuthenticationCredentials.swift
  Storage/NativeCredentialStore.swift
  Storage/NativePasswordFile.swift
  Storage/NativeLaunchCredentials.swift
  Storage/NativeKeychainBacking.swift
  Storage/NativeProfileHistoryStore.swift
  Storage/NativeRecentHistory.swift
  Storage/NativeProfileLibrary.swift
  Settings/NativeInputSettings.swift
  Settings/NativeScaling.swift
  Settings/NativeSessionEncodingDraft.swift
  Settings/NativeSessionSecurityDraft.swift
  Settings/NativeConnectionDraft.swift
  Settings/NativeRemoteResizeDraft.swift
  Settings/NativeRemoteResizePolicy.swift
  Settings/NativeFullscreenPolicy.swift
  Storage/NativeFullscreenPreferences.swift
  Settings/NativeFullscreenDraft.swift
  Desktop/NativeFullscreenState.swift
  Desktop/NativeRemoteResizeCoordinator.swift
  Desktop/NativeDesktopCommands.swift
  Desktop/NativeDesktopCanvas.swift
  Desktop/NativeConnectionStatisticsOverlay.swift
  Desktop/NativeFullscreenContentView.swift
  Desktop/NativeFullscreenController.swift
  Desktop/NativeKeyboardCapture.swift
  Desktop/NativePresentationPool.swift
  Desktop/NativeTileRenderer.swift
  Desktop/NativeCursorSampler.swift
  Desktop/NativeCursorPresentation.swift
  Desktop/NativeGeometry.swift
  Desktop/NativeDesktopView.swift)
set_target_properties(tidyvnc_macos_bridge PROPERTIES
  Swift_MODULE_NAME TidyVNCNative
  Swift_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/modules)
target_compile_options(tidyvnc_macos_bridge PRIVATE
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors -enable-testing
  -emit-localized-strings -emit-localized-strings-path ${CMAKE_CURRENT_BINARY_DIR}/localization
  -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
get_target_property(native_localization_sources tidyvnc_macos_bridge SOURCES)
set(native_localization_manifest "")
foreach(source IN LISTS native_localization_sources)
  if(source MATCHES "\\.swift$")
    get_filename_component(source "${source}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    string(APPEND native_localization_manifest "${source}\n")
  endif()
endforeach()
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/LocalizationSources.txt "${native_localization_manifest}")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(TARGET tidyvnc_macos_bridge POST_BUILD
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/macos/localization-source.py
    --record-build ${CMAKE_CURRENT_BINARY_DIR}/LocalizationSources.txt
    ${CMAKE_CURRENT_BINARY_DIR}/localization
  VERBATIM)
target_include_directories(tidyvnc_macos_bridge INTERFACE ${CMAKE_CURRENT_BINARY_DIR}/modules)
target_link_libraries(tidyvnc_macos_bridge PUBLIC tidyvnc_viewer_c tidyvnc_macos_keymap tidyvnc_macos_askpass "-lc++")

# CMake's unscanned Swift builds do not reliably rebuild downstream modules when
# an imported C struct changes but the Swift module interface stays identical.
# Propagate a content fingerprint as a Swift compile option so both this module
# and every consumer (including the separately exported Xcode app) recompile.
set(native_import_fingerprint "")
foreach(header IN ITEMS
    "${CMAKE_SOURCE_DIR}/viewer/bridge/tidyvnc.h"
    "${CMAKE_SOURCE_DIR}/viewer/bridge/module.modulemap"
    "${CMAKE_CURRENT_SOURCE_DIR}/KeyMap/NativeKeyMap.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/KeyMap/module.modulemap"
    "${CMAKE_CURRENT_SOURCE_DIR}/Tunnel/Askpass/NativeAskpass.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/Tunnel/Askpass/module.modulemap")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${header}")
  file(SHA256 "${header}" native_import_hash)
  string(APPEND native_import_fingerprint "${native_import_hash}")
endforeach()
string(SHA256 native_import_fingerprint "${native_import_fingerprint}")
target_compile_options(tidyvnc_macos_bridge PUBLIC
  "$<$<COMPILE_LANGUAGE:Swift>:-DTIDYVNC_C_IMPORT_${native_import_fingerprint}>")

# CMake 3.30 passes the SDK to Swift but does not translate the macOS deployment
# target into a Swift target triple. Keep Swift and C++ architecture/floor aligned.
set(native_swift_arch "${CMAKE_OSX_ARCHITECTURES}")
if(NOT native_swift_arch)
  set(native_swift_arch "${CMAKE_SYSTEM_PROCESSOR}")
endif()

# Build-tree export consumed by the separate Xcode application project. CMake
# owns the native core dependency list, including enabled crypto libraries.
export(TARGETS tidyvnc_macos_bridge tidyvnc_macos_keymap tidyvnc_macos_askpass tidyvnc_viewer_c
  tidyvnc_viewer_core tidyvnc_viewer_platform rfbclient rfb network rdr core
  NAMESPACE TidyVNC:: FILE ${CMAKE_BINARY_DIR}/NativeTargets.cmake)
file(WRITE ${CMAKE_BINARY_DIR}/NativeBuild.cmake
  "set(TIDYVNC_SOURCE_DIR \"${CMAKE_SOURCE_DIR}\")\nset(VERSION \"${VERSION}\")\n"
  "set(TIDYVNC_NATIVE_CONFIGURATION \"${CMAKE_BUILD_TYPE}\")\n"
  "set(TIDYVNC_NATIVE_SDK \"${CMAKE_OSX_SYSROOT}\")\n"
  "set(TIDYVNC_NATIVE_ARCHITECTURE \"${native_swift_arch}\")\n"
  "set(TIDYVNC_NATIVE_DEPLOYMENT_TARGET \"${CMAKE_OSX_DEPLOYMENT_TARGET}\")\n")
list(LENGTH native_swift_arch native_swift_arch_count)
if(NOT native_swift_arch_count EQUAL 1)
  message(FATAL_ERROR "The experimental native bridge currently needs one CMAKE_OSX_ARCHITECTURES value per build directory")
endif()
if(CMAKE_OSX_DEPLOYMENT_TARGET)
  set(native_swift_triple "${native_swift_arch}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}")
  target_compile_options(tidyvnc_macos_bridge PUBLIC "$<$<COMPILE_LANGUAGE:Swift>:-target;${native_swift_triple}>")
  target_link_options(tidyvnc_macos_bridge INTERFACE "$<$<LINK_LANGUAGE:Swift>:-target;${native_swift_triple}>")
endif()
