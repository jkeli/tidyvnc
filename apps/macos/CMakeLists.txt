# The application is an Xcode target; the portable dependency graph stays in
# the root CMake build. Use build.py to configure both with the same toolchain.
cmake_minimum_required(VERSION 3.29)
project(TidyVNCNativeApp LANGUAGES CXX Swift)
if(NOT APPLE OR NOT CMAKE_GENERATOR STREQUAL "Xcode")
  message(FATAL_ERROR "Use the Xcode generator through apps/macos/build.py")
endif()
if(NOT EXISTS "${NATIVE_CORE_BUILD}/NativeTargets.cmake")
  message(FATAL_ERROR "NATIVE_CORE_BUILD must name a configured native core build")
endif()
find_package(Threads REQUIRED)
include(${NATIVE_CORE_BUILD}/NativeBuild.cmake)
include(${NATIVE_CORE_BUILD}/NativeTargets.cmake)
set(BUILD 0)
configure_file(${TIDYVNC_SOURCE_DIR}/release/Info.plist.in ${CMAKE_CURRENT_BINARY_DIR}/BaseInfo.plist @ONLY)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/native_plist.py
  ${CMAKE_CURRENT_BINARY_DIR}/BaseInfo.plist ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  OUTPUT_VARIABLE native_bundle_identifier OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)
set(resources ${TIDYVNC_SOURCE_DIR}/media/icons/tidyvnc.icns
  ${TIDYVNC_SOURCE_DIR}/README.rst ${TIDYVNC_SOURCE_DIR}/LICENCE.TXT
  ${CMAKE_CURRENT_SOURCE_DIR}/Credits.rtf
  ${CMAKE_CURRENT_SOURCE_DIR}/Localizable.xcstrings)
set_source_files_properties(${resources} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
set(askpass_helper ${NATIVE_CORE_BUILD}/platform/macos/tidyvnc-ssh-askpass)
set_source_files_properties(${askpass_helper} PROPERTIES MACOSX_PACKAGE_LOCATION MacOS)
add_executable(TidyVNC MACOSX_BUNDLE TidyVNC/TidyVNCMain.swift TidyVNC/TidyVNCApp.swift TidyVNC/ConnectionModel.swift TidyVNC/AuthenticationSheet.swift TidyVNC/TrustDetailsView.swift
  TidyVNC/SecuritySettingsFields.swift TidyVNC/TrustFileSettingsFields.swift TidyVNC/TrustLibraryView.swift TidyVNC/PreferencesSettingsView.swift TidyVNC/EncodingSettingsFields.swift TidyVNC/ConnectionSettingsFields.swift
  TidyVNC/FullscreenDefaultsFields.swift
  TidyVNC/ApplicationHelpView.swift
  TidyVNC/SSHAuthenticationSheet.swift
  ${askpass_helper}
  TidyVNC/DocumentExportView.swift
  TidyVNC/ListenerModel.swift
  TidyVNC/ListenerView.swift
  TidyVNC/DefaultsImportView.swift
  TidyVNC/HistoryImportView.swift
  TidyVNC/DocumentReviewView.swift
  TidyVNC/DocumentMonitorMappingView.swift
  TidyVNC/FullscreenSettingsSheet.swift
  TidyVNC/RemoteResizeSheet.swift
  TidyVNC/RemoteResizePolicySheet.swift
  TidyVNC/RemoteResizeSettingsFields.swift TidyVNC/SessionSecuritySheet.swift TidyVNC/SessionEncodingSheet.swift TidyVNC/RecentConnectionsView.swift TidyVNC/ProfileLibraryView.swift TidyVNC/EndpointIssueView.swift TidyVNC/DesktopActions.swift TidyVNC/ConnectionInformationSheet.swift TidyVNC/ConnectionStatisticsOverlay.swift TidyVNC/InputSettingsSheet.swift TidyVNC/InputDefaultsFields.swift TidyVNC/ScalingSettingsSheet.swift TidyVNC/ScalingDefaultsFields.swift ${resources})
target_link_libraries(TidyVNC PRIVATE TidyVNC::tidyvnc_macos_bridge)
set_target_properties(TidyVNC PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_BINARY_DIR}/Info.plist
  Swift_MODULE_NAME TidyVNCApp
  XCODE_GENERATE_SCHEME YES
  XCODE_ATTRIBUTE_SWIFT_VERSION 6.0
  XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME TidyVNCApp
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER ${native_bundle_identifier}
  XCODE_ATTRIBUTE_SWIFT_INCLUDE_PATHS "${NATIVE_CORE_BUILD}/platform/macos/modules ${TIDYVNC_SOURCE_DIR}/viewer/bridge ${TIDYVNC_SOURCE_DIR}/platform/macos/KeyMap ${TIDYVNC_SOURCE_DIR}/platform/macos/Tunnel/Askpass"
  XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY complete
  XCODE_ATTRIBUTE_SWIFT_TREAT_WARNINGS_AS_ERRORS YES
  XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE wholemodule
  XCODE_ATTRIBUTE_EXECUTABLE_NAME vncviewer
  XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
  XCODE_ATTRIBUTE_CODE_SIGN_STYLE Manual
  # Local development links Homebrew dylibs. N6 must bundle/sign dependencies
  # before enabling hardened runtime for a distributable app.
  XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
  XCODE_ATTRIBUTE_CLANG_MODULE_CACHE_PATH ${CMAKE_CURRENT_BINARY_DIR}/ModuleCache
  XCODE_ATTRIBUTE_SWIFT_MODULE_CACHE_PATH ${CMAKE_CURRENT_BINARY_DIR}/ModuleCache)
add_custom_command(TARGET TidyVNC POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:TidyVNC>/Contents/MacOS/tidyvnc-ssh-askpass"
  VERBATIM)
