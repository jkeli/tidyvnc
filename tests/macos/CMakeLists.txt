enable_testing()
add_executable(native-panning-tests NativePanningTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift ../../apps/macos/TidyVNC/DesktopActions.swift)
set_target_properties(native-panning-tests PROPERTIES Swift_MODULE_NAME NativePanningTests)
target_compile_options(native-panning-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-panning-tests PRIVATE support)
target_link_libraries(native-panning-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.AccessiblePanning COMMAND native-panning-tests)
set_tests_properties(NativeDesktop.AccessiblePanning PROPERTIES TIMEOUT 40)
set_directory_properties(PROPERTIES COMPILE_DEFINITIONS "")
add_library(native-test-peer STATIC support/peer.cxx support/resize-peer.cxx)
target_link_libraries(native-test-peer PRIVATE tidyvnc_viewer_core)
add_executable(native-loopback-peer support/peer-main.cxx)
target_link_libraries(native-loopback-peer PRIVATE native-test-peer)
add_executable(native-bridge-tests NativeBridgeTests.swift)
set_target_properties(native-bridge-tests PROPERTIES Swift_MODULE_NAME NativeBridgeTests)
target_compile_options(native-bridge-tests PRIVATE
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library
  -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-bridge-tests PRIVATE support)
target_link_libraries(native-bridge-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeBridge.OwnershipAndLoopback COMMAND native-bridge-tests)
set_tests_properties(NativeBridge.OwnershipAndLoopback PROPERTIES TIMEOUT 40)
add_executable(native-desktop-tests NativeDesktopTests.swift)
set_target_properties(native-desktop-tests PROPERTIES Swift_MODULE_NAME NativeDesktopTests)
target_compile_options(native-desktop-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-desktop-tests PRIVATE support)
target_link_libraries(native-desktop-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.RenderingAndInput COMMAND native-desktop-tests)
set_tests_properties(NativeDesktop.RenderingAndInput PROPERTIES TIMEOUT 40)
add_executable(native-clipboard-tests NativeClipboardTests.swift)
set_target_properties(native-clipboard-tests PROPERTIES Swift_MODULE_NAME NativeClipboardTests)
target_compile_options(native-clipboard-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-clipboard-tests PRIVATE support)
target_link_libraries(native-clipboard-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeClipboard.PasteboardAndRouting COMMAND native-clipboard-tests)
set_tests_properties(NativeClipboard.PasteboardAndRouting PROPERTIES TIMEOUT 40)
add_executable(native-display-tests NativeDisplayTests.swift)
set_target_properties(native-display-tests PROPERTIES Swift_MODULE_NAME NativeDisplayTests)
target_compile_options(native-display-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-display-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeDisplay.TopologyAndSelection COMMAND native-display-tests)
set_tests_properties(NativeDisplay.TopologyAndSelection PROPERTIES TIMEOUT 40)
add_executable(native-preferences-tests NativePreferencesTests.swift)
set_target_properties(native-preferences-tests PROPERTIES Swift_MODULE_NAME NativePreferencesTests)
target_compile_options(native-preferences-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-preferences-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativePreferences.RevisionAndPersistence COMMAND native-preferences-tests)
set_tests_properties(NativePreferences.RevisionAndPersistence PROPERTIES TIMEOUT 40)
add_executable(native-settings-tests NativeSettingsTests.swift support/TrustFixtures.swift ../../apps/macos/TidyVNC/TrustDetailsView.swift ../../apps/macos/TidyVNC/TrustLibraryView.swift ../../apps/macos/TidyVNC/AuthenticationSheet.swift ../../apps/macos/TidyVNC/ConnectionModel.swift support/EncodingTarget.swift support/HistoryBacking.swift ../../apps/macos/TidyVNC/SecuritySettingsFields.swift ../../apps/macos/TidyVNC/TrustFileSettingsFields.swift ../../apps/macos/TidyVNC/PreferencesSettingsView.swift ../../apps/macos/TidyVNC/EncodingSettingsFields.swift ../../apps/macos/TidyVNC/ConnectionSettingsFields.swift
  ../../apps/macos/TidyVNC/FullscreenSettingsSheet.swift
  ../../apps/macos/TidyVNC/RemoteResizeSheet.swift
  ../../apps/macos/TidyVNC/RemoteResizePolicySheet.swift
  ../../apps/macos/TidyVNC/FullscreenDefaultsFields.swift
  ../../apps/macos/TidyVNC/RemoteResizeSettingsFields.swift ../../apps/macos/TidyVNC/SessionSecuritySheet.swift ../../apps/macos/TidyVNC/SessionEncodingSheet.swift ../../apps/macos/TidyVNC/RecentConnectionsView.swift ../../apps/macos/TidyVNC/ProfileLibraryView.swift ../../apps/macos/TidyVNC/EndpointIssueView.swift ../../apps/macos/TidyVNC/ScalingSettingsSheet.swift ../../apps/macos/TidyVNC/ScalingDefaultsFields.swift ../../apps/macos/TidyVNC/InputSettingsSheet.swift ../../apps/macos/TidyVNC/InputDefaultsFields.swift ../../apps/macos/TidyVNC/ConnectionInformationSheet.swift ../../apps/macos/TidyVNC/ConnectionStatisticsOverlay.swift)
target_sources(native-settings-tests PRIVATE
  ../../apps/macos/TidyVNC/ConnectionContent.swift
  ../../apps/macos/TidyVNC/DefaultsImportView.swift
  ../../apps/macos/TidyVNC/HistoryImportView.swift
  ../../apps/macos/TidyVNC/DesktopActions.swift
  ../../apps/macos/TidyVNC/SSHAuthenticationSheet.swift)
set_target_properties(native-settings-tests PROPERTIES Swift_MODULE_NAME NativeSettingsTests)
target_compile_options(native-settings-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-settings-tests PRIVATE support)
target_link_libraries(native-settings-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeSettings.DraftRendering COMMAND native-settings-tests ${CMAKE_CURRENT_BINARY_DIR}/settings-render)
set_tests_properties(NativeSettings.DraftRendering PROPERTIES TIMEOUT 40)
add_executable(native-encoding-draft-tests NativeEncodingDraftTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift support/EncodingTarget.swift)
set_target_properties(native-encoding-draft-tests PROPERTIES Swift_MODULE_NAME NativeEncodingDraftTests)
target_compile_options(native-encoding-draft-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-encoding-draft-tests PRIVATE support)
target_link_libraries(native-encoding-draft-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeEncoding.DraftAndSessionIsolation COMMAND native-encoding-draft-tests)
set_tests_properties(NativeEncoding.DraftAndSessionIsolation PROPERTIES TIMEOUT 40)
add_executable(native-profile-history-tests NativeProfileHistoryTests.swift)
set_target_properties(native-profile-history-tests PROPERTIES Swift_MODULE_NAME NativeProfileHistoryTests)
target_compile_options(native-profile-history-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-profile-history-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeProfiles.AtomicHistoryAndPersistence COMMAND native-profile-history-tests)
set_tests_properties(NativeProfiles.AtomicHistoryAndPersistence PROPERTIES TIMEOUT 40)
add_executable(native-recent-history-tests NativeRecentHistoryTests.swift support/HistoryBacking.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-recent-history-tests PROPERTIES Swift_MODULE_NAME NativeRecentHistoryTests)
target_compile_options(native-recent-history-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-recent-history-tests PRIVATE support)
target_link_libraries(native-recent-history-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeHistory.ModelAndConnectionRouting COMMAND native-recent-history-tests)
set_tests_properties(NativeHistory.ModelAndConnectionRouting PROPERTIES TIMEOUT 40)
add_executable(native-profile-library-tests NativeProfileLibraryTests.swift support/HistoryBacking.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-profile-library-tests PROPERTIES Swift_MODULE_NAME NativeProfileLibraryTests)
target_compile_options(native-profile-library-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-profile-library-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeProfiles.EditorAndSessionDefaults COMMAND native-profile-library-tests)
set_tests_properties(NativeProfiles.EditorAndSessionDefaults PROPERTIES TIMEOUT 40)
add_executable(native-endpoint-tests NativeEndpointTests.swift support/HistoryBacking.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-endpoint-tests PROPERTIES Swift_MODULE_NAME NativeEndpointTests)
target_compile_options(native-endpoint-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-endpoint-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeEndpoint.ValidationAndFormGating COMMAND native-endpoint-tests)
set_tests_properties(NativeEndpoint.ValidationAndFormGating PROPERTIES TIMEOUT 40)

add_executable(native-scaling-tests NativeScalingTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-scaling-tests PROPERTIES Swift_MODULE_NAME NativeScalingTests)
target_compile_options(native-scaling-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-scaling-tests PRIVATE support)
target_link_libraries(native-scaling-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeScaling.DraftGeometryAndIsolation COMMAND native-scaling-tests)
set_tests_properties(NativeScaling.DraftGeometryAndIsolation PROPERTIES TIMEOUT 40)

add_executable(native-tile-renderer-tests NativeTileRendererTests.swift)
set_target_properties(native-tile-renderer-tests PROPERTIES Swift_MODULE_NAME NativeTileRendererTests)
target_compile_options(native-tile-renderer-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-tile-renderer-tests PRIVATE support)
target_link_libraries(native-tile-renderer-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeRenderer.TilesAndBoundedScheduling COMMAND native-tile-renderer-tests)
set_tests_properties(NativeRenderer.TilesAndBoundedScheduling PROPERTIES TIMEOUT 40)

add_executable(native-presentation-tests NativePresentationTests.swift)
set_target_properties(native-presentation-tests PROPERTIES Swift_MODULE_NAME NativePresentationTests)
target_compile_options(native-presentation-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-presentation-tests PRIVATE support)
target_link_libraries(native-presentation-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativePresentation.CompositionDamageAndDrain COMMAND native-presentation-tests ${CMAKE_CURRENT_BINARY_DIR}/presentation-render)
set_tests_properties(NativePresentation.CompositionDamageAndDrain PROPERTIES TIMEOUT 60)

add_executable(native-cursor-tests NativeCursorTests.swift)
set_target_properties(native-cursor-tests PROPERTIES Swift_MODULE_NAME NativeCursorTests)
target_compile_options(native-cursor-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-cursor-tests PRIVATE support)
target_link_libraries(native-cursor-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCursor.SamplingAndOwnership COMMAND native-cursor-tests)
set_tests_properties(NativeCursor.SamplingAndOwnership PROPERTIES TIMEOUT 40)

add_executable(native-cursor-presentation-tests NativeCursorPresentationTests.swift)
set_target_properties(native-cursor-presentation-tests PROPERTIES Swift_MODULE_NAME NativeCursorPresentationTests)
target_compile_options(native-cursor-presentation-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-cursor-presentation-tests PRIVATE support)
target_link_libraries(native-cursor-presentation-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCursor.PresentationAndDrain COMMAND native-cursor-presentation-tests ${CMAKE_CURRENT_BINARY_DIR}/cursor-render)
set_tests_properties(NativeCursor.PresentationAndDrain PROPERTIES TIMEOUT 60)

add_executable(native-input-tests NativeInputTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-input-tests PROPERTIES Swift_MODULE_NAME NativeInputTests)
target_compile_options(native-input-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-input-tests PRIVATE support)
target_link_libraries(native-input-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInput.DraftRoutingAndRelease COMMAND native-input-tests)
set_tests_properties(NativeInput.DraftRoutingAndRelease PROPERTIES TIMEOUT 40)

add_executable(native-shortcut-tests NativeShortcutTests.swift)
set_target_properties(native-shortcut-tests PROPERTIES Swift_MODULE_NAME NativeShortcutTests)
target_compile_options(native-shortcut-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-shortcut-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeShortcuts.ClassificationAndRouting COMMAND native-shortcut-tests)
set_tests_properties(NativeShortcuts.ClassificationAndRouting PROPERTIES TIMEOUT 40)

add_executable(native-command-tests NativeCommandTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift ../../apps/macos/TidyVNC/DesktopActions.swift)
set_target_properties(native-command-tests PROPERTIES Swift_MODULE_NAME NativeCommandTests)
target_compile_options(native-command-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-command-tests PRIVATE support)
target_link_libraries(native-command-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCommands.RoutingAndModifierLifetime COMMAND native-command-tests)
set_tests_properties(NativeCommands.RoutingAndModifierLifetime PROPERTIES TIMEOUT 40)

add_executable(native-shortcut-dispatch-tests NativeShortcutDispatchTests.swift)
set_target_properties(native-shortcut-dispatch-tests PROPERTIES Swift_MODULE_NAME NativeShortcutDispatchTests)
target_compile_options(native-shortcut-dispatch-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-shortcut-dispatch-tests PRIVATE support)
target_link_libraries(native-shortcut-dispatch-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeShortcuts.AppKitDispatchAndCaptureLifetime COMMAND native-shortcut-dispatch-tests)
set_tests_properties(NativeShortcuts.AppKitDispatchAndCaptureLifetime PROPERTIES TIMEOUT 40)

add_executable(native-input-persistence-tests NativeInputPersistenceTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-input-persistence-tests PROPERTIES Swift_MODULE_NAME NativeInputPersistenceTests)
target_compile_options(native-input-persistence-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-input-persistence-tests PRIVATE support)
target_link_libraries(native-input-persistence-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInput.PersistenceAndInitialPolicy COMMAND native-input-persistence-tests)
set_tests_properties(NativeInput.PersistenceAndInitialPolicy PROPERTIES TIMEOUT 40)

add_executable(native-scaling-persistence-tests NativeScalingPersistenceTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-scaling-persistence-tests PROPERTIES Swift_MODULE_NAME NativeScalingPersistenceTests)
target_compile_options(native-scaling-persistence-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-scaling-persistence-tests PRIVATE support)
target_link_libraries(native-scaling-persistence-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeScaling.PersistenceAndInitialGeometry COMMAND native-scaling-persistence-tests)
set_tests_properties(NativeScaling.PersistenceAndInitialGeometry PROPERTIES TIMEOUT 40)

add_executable(native-connection-issue-tests NativeConnectionIssueTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-connection-issue-tests PROPERTIES Swift_MODULE_NAME NativeConnectionIssueTests)
target_compile_options(native-connection-issue-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-connection-issue-tests PRIVATE support)
target_link_libraries(native-connection-issue-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeConnection.ErrorsAndRetry COMMAND native-connection-issue-tests)
set_tests_properties(NativeConnection.ErrorsAndRetry PROPERTIES TIMEOUT 40)

add_executable(native-credential-key-tests NativeCredentialKeyTests.swift)
set_target_properties(native-credential-key-tests PROPERTIES Swift_MODULE_NAME NativeCredentialKeyTests)
target_compile_options(native-credential-key-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-credential-key-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeCredentials.CanonicalIdentity COMMAND native-credential-key-tests)
set_tests_properties(NativeCredentials.CanonicalIdentity PROPERTIES TIMEOUT 40)

add_executable(native-credential-store-tests NativeCredentialStoreTests.swift)
set_target_properties(native-credential-store-tests PROPERTIES Swift_MODULE_NAME NativeCredentialStoreTests)
target_compile_options(native-credential-store-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-credential-store-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeCredentials.StorePolicyAndLifetime COMMAND native-credential-store-tests)
set_tests_properties(NativeCredentials.StorePolicyAndLifetime PROPERTIES TIMEOUT 40)

add_executable(native-credential-retention-tests NativeCredentialRetentionTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-credential-retention-tests PROPERTIES Swift_MODULE_NAME NativeCredentialRetentionTests)
target_compile_options(native-credential-retention-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-credential-retention-tests PRIVATE support)
target_link_libraries(native-credential-retention-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCredentials.AuthenticationRetention COMMAND native-credential-retention-tests)
set_tests_properties(NativeCredentials.AuthenticationRetention PROPERTIES TIMEOUT 40)

add_executable(native-trust-tests NativeTrustTests.swift support/TrustFixtures.swift)
set_target_properties(native-trust-tests PROPERTIES Swift_MODULE_NAME NativeTrustTests)
target_compile_options(native-trust-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-trust-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeTrust.PolicyAndPresentation COMMAND native-trust-tests)
set_tests_properties(NativeTrust.PolicyAndPresentation PROPERTIES TIMEOUT 40)

add_executable(native-legacy-trust-tests NativeLegacyTrustTests.swift support/TrustFixtures.swift)
set_target_properties(native-legacy-trust-tests PROPERTIES Swift_MODULE_NAME NativeLegacyTrustTests)
target_compile_options(native-legacy-trust-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-legacy-trust-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeTrust.LegacyStoreAndDecisions COMMAND native-legacy-trust-tests)
set_tests_properties(NativeTrust.LegacyStoreAndDecisions PROPERTIES TIMEOUT 40)

add_executable(native-trust-store-tests NativeTrustStoreTests.swift support/TrustFixtures.swift)
set_target_properties(native-trust-store-tests PROPERTIES Swift_MODULE_NAME NativeTrustStoreTests)
target_compile_options(native-trust-store-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-trust-store-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeTrust.ScopedPersistenceAndRecovery COMMAND native-trust-store-tests)
set_tests_properties(NativeTrust.ScopedPersistenceAndRecovery PROPERTIES TIMEOUT 40)

add_executable(native-host-key-tests NativeHostKeyTests.swift support/TrustFixtures.swift)
set_target_properties(native-host-key-tests PROPERTIES Swift_MODULE_NAME NativeHostKeyTests)
target_compile_options(native-host-key-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-host-key-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeTrust.HostKeyPersistenceAndPolicy COMMAND native-host-key-tests)
set_tests_properties(NativeTrust.HostKeyPersistenceAndPolicy PROPERTIES TIMEOUT 40)

add_executable(native-trust-file-tests NativeTrustFileTests.swift)
set_target_properties(native-trust-file-tests PROPERTIES Swift_MODULE_NAME NativeTrustFileTests)
target_compile_options(native-trust-file-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-trust-file-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeTrust.ConfiguredFilesAndInheritance COMMAND native-trust-file-tests)
set_tests_properties(NativeTrust.ConfiguredFilesAndInheritance PROPERTIES TIMEOUT 40)

add_executable(native-security-tests NativeSecurityTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-security-tests PROPERTIES Swift_MODULE_NAME NativeSecurityTests)
target_compile_options(native-security-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-security-tests PRIVATE support)
target_link_libraries(native-security-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeSecurity.SelectionPersistenceAndWire COMMAND native-security-tests)
set_tests_properties(NativeSecurity.SelectionPersistenceAndWire PROPERTIES TIMEOUT 40)

add_executable(native-connection-options-tests NativeConnectionOptionsTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-connection-options-tests PROPERTIES Swift_MODULE_NAME NativeConnectionOptionsTests)
target_compile_options(native-connection-options-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-connection-options-tests PRIVATE support)
target_link_libraries(native-connection-options-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeConnection.OptionsPersistenceAndWire COMMAND native-connection-options-tests)
set_tests_properties(NativeConnection.OptionsPersistenceAndWire PROPERTIES TIMEOUT 40)

add_executable(native-remote-layout-tests NativeRemoteLayoutTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-remote-layout-tests PROPERTIES Swift_MODULE_NAME NativeRemoteLayoutTests)
target_compile_options(native-remote-layout-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-remote-layout-tests PRIVATE support)
target_link_libraries(native-remote-layout-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeRemoteLayout.WireAndLifetime COMMAND native-remote-layout-tests)
set_tests_properties(NativeRemoteLayout.WireAndLifetime PROPERTIES TIMEOUT 45)

add_executable(native-automatic-resize-tests NativeAutomaticResizeTests.swift)
set_target_properties(native-automatic-resize-tests PROPERTIES Swift_MODULE_NAME NativeAutomaticResizeTests)
target_compile_options(native-automatic-resize-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-automatic-resize-tests PRIVATE support)
target_link_libraries(native-automatic-resize-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeRemoteResize.PolicyAndViewport COMMAND native-automatic-resize-tests)
set_tests_properties(NativeRemoteResize.PolicyAndViewport PROPERTIES TIMEOUT 45)

add_executable(native-resize-persistence-tests NativeResizePersistenceTests.swift)
set_target_properties(native-resize-persistence-tests PROPERTIES Swift_MODULE_NAME NativeResizePersistenceTests)
target_compile_options(native-resize-persistence-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-resize-persistence-tests PRIVATE support)
target_link_libraries(native-resize-persistence-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeRemoteResize.PersistenceAndSources COMMAND native-resize-persistence-tests)
set_tests_properties(NativeRemoteResize.PersistenceAndSources PROPERTIES TIMEOUT 40)

add_executable(native-canvas-tests NativeCanvasTests.swift)
set_target_properties(native-canvas-tests PROPERTIES Swift_MODULE_NAME NativeCanvasTests)
target_compile_options(native-canvas-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-canvas-tests PRIVATE support)
target_link_libraries(native-canvas-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.CanvasGeometryAndPresentation COMMAND native-canvas-tests)
set_tests_properties(NativeDesktop.CanvasGeometryAndPresentation PROPERTIES TIMEOUT 40)

add_executable(native-surface-focus-tests NativeSurfaceFocusTests.swift)
set_target_properties(native-surface-focus-tests PROPERTIES Swift_MODULE_NAME NativeSurfaceFocusTests)
target_compile_options(native-surface-focus-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-surface-focus-tests PRIVATE support)
target_link_libraries(native-surface-focus-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.SurfaceFocusAndCommands COMMAND native-surface-focus-tests)
set_tests_properties(NativeDesktop.SurfaceFocusAndCommands PROPERTIES TIMEOUT 40)

add_executable(native-shared-canvas-tests NativeSharedCanvasTests.swift)
set_target_properties(native-shared-canvas-tests PROPERTIES Swift_MODULE_NAME NativeSharedCanvasTests)
target_compile_options(native-shared-canvas-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-shared-canvas-tests PRIVATE support)
target_link_libraries(native-shared-canvas-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.SharedCanvasCoordination COMMAND native-shared-canvas-tests)
set_tests_properties(NativeDesktop.SharedCanvasCoordination PROPERTIES TIMEOUT 40)

add_executable(native-fullscreen-tests NativeFullscreenTests.swift)
set_target_properties(native-fullscreen-tests PROPERTIES Swift_MODULE_NAME NativeFullscreenTests)
target_compile_options(native-fullscreen-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-tests PRIVATE support)
target_link_libraries(native-fullscreen-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDesktop.FullscreenOwnershipAndTransitions COMMAND native-fullscreen-tests)
set_tests_properties(NativeDesktop.FullscreenOwnershipAndTransitions PROPERTIES TIMEOUT 40)

# Explicit developer comparison app; it is never linked into the shipped viewer.
add_executable(native-fullscreen-comparison MACOSX_BUNDLE FullscreenComparison.swift)
set_target_properties(native-fullscreen-comparison PROPERTIES
  Swift_MODULE_NAME NativeFullscreenComparison
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/FullscreenComparison-Info.plist.in)
target_compile_options(native-fullscreen-comparison PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-comparison PRIVATE support)
target_link_libraries(native-fullscreen-comparison PRIVATE tidyvnc_macos_bridge native-test-peer)
add_custom_command(TARGET native-fullscreen-comparison POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-fullscreen-comparison>"
  VERBATIM)
add_test(NAME NativeDesktop.FullscreenComparisonHarness COMMAND native-fullscreen-comparison --verify --output ${CMAKE_CURRENT_BINARY_DIR}/fullscreen-comparison-render)
set_tests_properties(NativeDesktop.FullscreenComparisonHarness PROPERTIES TIMEOUT 40)

add_executable(native-fullscreen-state-tests NativeFullscreenStateTests.swift
  ../../apps/macos/TidyVNC/ConnectionModel.swift ../../apps/macos/TidyVNC/FullscreenSettingsSheet.swift)
set_target_properties(native-fullscreen-state-tests PROPERTIES Swift_MODULE_NAME NativeFullscreenStateTests)
target_compile_options(native-fullscreen-state-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-state-tests PRIVATE support)
target_link_libraries(native-fullscreen-state-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeFullscreen.ConnectionAndPresentation COMMAND native-fullscreen-state-tests ${CMAKE_CURRENT_BINARY_DIR}/fullscreen-settings-render)
set_tests_properties(NativeFullscreen.ConnectionAndPresentation PROPERTIES TIMEOUT 40)

add_executable(native-fullscreen-persistence-tests NativeFullscreenPersistenceTests.swift)
set_target_properties(native-fullscreen-persistence-tests PROPERTIES Swift_MODULE_NAME NativeFullscreenPersistenceTests)
target_compile_options(native-fullscreen-persistence-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-persistence-tests PRIVATE support)
target_link_libraries(native-fullscreen-persistence-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeFullscreen.PersistenceAndSources COMMAND native-fullscreen-persistence-tests)
set_tests_properties(NativeFullscreen.PersistenceAndSources PROPERTIES TIMEOUT 40)

add_executable(native-fullscreen-resize-tests NativeFullscreenResizeTests.swift)
set_target_properties(native-fullscreen-resize-tests PROPERTIES Swift_MODULE_NAME NativeFullscreenResizeTests)
target_compile_options(native-fullscreen-resize-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-resize-tests PRIVATE support)
target_link_libraries(native-fullscreen-resize-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeFullscreen.AutomaticRemoteLayout COMMAND native-fullscreen-resize-tests)
set_tests_properties(NativeFullscreen.AutomaticRemoteLayout PROPERTIES TIMEOUT 45)

add_executable(native-document-tests NativeConnectionDocumentTests.swift)
set_target_properties(native-document-tests PROPERTIES Swift_MODULE_NAME NativeConnectionDocumentTests)
target_compile_options(native-document-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeDocuments.CodecOwnershipAndExport COMMAND native-document-tests)
set_tests_properties(NativeDocuments.CodecOwnershipAndExport PROPERTIES TIMEOUT 30)

add_executable(native-document-resolution-tests NativeDocumentResolutionTests.swift)
set_target_properties(native-document-resolution-tests PROPERTIES Swift_MODULE_NAME NativeDocumentResolutionTests)
target_compile_options(native-document-resolution-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-document-resolution-tests PRIVATE support)
target_link_libraries(native-document-resolution-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDocuments.SemanticsAndSessionResolution COMMAND native-document-resolution-tests)
set_tests_properties(NativeDocuments.SemanticsAndSessionResolution PROPERTIES TIMEOUT 30)

add_executable(native-fullscreen-statistics-tests NativeFullscreenStatisticsTests.swift)
set_target_properties(native-fullscreen-statistics-tests PROPERTIES Swift_MODULE_NAME NativeFullscreenStatisticsTests)
target_compile_options(native-fullscreen-statistics-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-fullscreen-statistics-tests PRIVATE support)
target_link_libraries(native-fullscreen-statistics-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeFullscreen.StatisticsAndInputIsolation COMMAND native-fullscreen-statistics-tests ${CMAKE_CURRENT_BINARY_DIR}/fullscreen-statistics-render)
set_tests_properties(NativeFullscreen.StatisticsAndInputIsolation PROPERTIES TIMEOUT 40)

add_executable(native-document-open-tests NativeDocumentOpenTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-document-open-tests PROPERTIES Swift_MODULE_NAME NativeDocumentOpenTests)
target_compile_options(native-document-open-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-open-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeDocuments.FileReviewAndAdmission COMMAND native-document-open-tests)
set_tests_properties(NativeDocuments.FileReviewAndAdmission PROPERTIES TIMEOUT 30)

add_executable(native-document-launch-tests NativeDocumentLaunchTests.swift)
set_target_properties(native-document-launch-tests PROPERTIES Swift_MODULE_NAME NativeDocumentLaunchTests)
target_compile_options(native-document-launch-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-launch-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeDocuments.LaunchRoutingAndQuit COMMAND native-document-launch-tests)
set_tests_properties(NativeDocuments.LaunchRoutingAndQuit PROPERTIES TIMEOUT 30)

add_executable(native-document-launch-ui-tests MACOSX_BUNDLE NativeDocumentLaunchUITests.swift)
set_target_properties(native-document-launch-ui-tests PROPERTIES Swift_MODULE_NAME NativeDocumentLaunchUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/DocumentLaunch-Info.plist.in)
target_compile_options(native-document-launch-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-launch-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-document-launch-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-document-launch-ui-tests>" VERBATIM)
add_test(NAME NativeDocuments.SwiftUIWindowActionLifetime COMMAND native-document-launch-ui-tests)
set_tests_properties(NativeDocuments.SwiftUIWindowActionLifetime PROPERTIES TIMEOUT 40)

add_executable(native-document-export-tests NativeDocumentExportTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-document-export-tests PROPERTIES Swift_MODULE_NAME NativeDocumentExportTests)
target_compile_options(native-document-export-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-document-export-tests PRIVATE support)
target_link_libraries(native-document-export-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeDocuments.LiveExportAndLossReview COMMAND native-document-export-tests)
set_tests_properties(NativeDocuments.LiveExportAndLossReview PROPERTIES TIMEOUT 30)

add_executable(native-document-save-tests NativeDocumentSaveTests.swift ../../apps/macos/TidyVNC/DocumentExportView.swift)
set_target_properties(native-document-save-tests PROPERTIES Swift_MODULE_NAME NativeDocumentSaveTests)
target_compile_options(native-document-save-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-save-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeDocuments.AtomicSaveAndReviewLifecycle COMMAND native-document-save-tests)
set_tests_properties(NativeDocuments.AtomicSaveAndReviewLifecycle PROPERTIES TIMEOUT 40)

add_executable(native-defaults-import-tests NativeDefaultsImportTests.swift)
set_target_properties(native-defaults-import-tests PROPERTIES Swift_MODULE_NAME NativeDefaultsImportTests)
target_compile_options(native-defaults-import-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-defaults-import-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeImport.DefaultsProjectionAndCommit COMMAND native-defaults-import-tests)
set_tests_properties(NativeImport.DefaultsProjectionAndCommit PROPERTIES TIMEOUT 30)

add_executable(native-import-flow-tests NativeImportFlowTests.swift)
set_target_properties(native-import-flow-tests PROPERTIES Swift_MODULE_NAME NativeImportFlowTests)
target_compile_options(native-import-flow-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-import-flow-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeImport.SourceDiscoveryAndReviewLifetime COMMAND native-import-flow-tests)
set_tests_properties(NativeImport.SourceDiscoveryAndReviewLifetime PROPERTIES TIMEOUT 30)

add_executable(native-import-ui-tests MACOSX_BUNDLE NativeImportUITests.swift ../../apps/macos/TidyVNC/DefaultsImportView.swift)
set_target_properties(native-import-ui-tests PROPERTIES Swift_MODULE_NAME NativeImportUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ImportUI-Info.plist.in)
target_compile_options(native-import-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-import-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-import-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-import-ui-tests>" VERBATIM)
add_test(NAME NativeImport.NativePresentationAndFirstUse COMMAND native-import-ui-tests --verify --output ${CMAKE_CURRENT_BINARY_DIR}/import-ui-render)
set_tests_properties(NativeImport.NativePresentationAndFirstUse PROPERTIES TIMEOUT 40)

add_executable(native-history-import-tests NativeHistoryImportTests.swift)
set_target_properties(native-history-import-tests PROPERTIES Swift_MODULE_NAME NativeHistoryImportTests)
target_compile_options(native-history-import-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-history-import-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeImport.HistoryProjectionAndTransaction COMMAND native-history-import-tests)
set_tests_properties(NativeImport.HistoryProjectionAndTransaction PROPERTIES TIMEOUT 30)

add_executable(native-history-import-ui-tests MACOSX_BUNDLE NativeHistoryImportUITests.swift ../../apps/macos/TidyVNC/HistoryImportView.swift)
set_target_properties(native-history-import-ui-tests PROPERTIES Swift_MODULE_NAME NativeHistoryImportUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/HistoryImportUI-Info.plist.in)
target_compile_options(native-history-import-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-history-import-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-history-import-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-history-import-ui-tests>" VERBATIM)
add_test(NAME NativeImport.HistoryPresentationAndFirstUse COMMAND native-history-import-ui-tests --verify --output ${CMAKE_CURRENT_BINARY_DIR}/history-import-ui-render)
set_tests_properties(NativeImport.HistoryPresentationAndFirstUse PROPERTIES TIMEOUT 40)

add_executable(native-document-mapping-ui-tests MACOSX_BUNDLE NativeDocumentMappingUITests.swift ../../apps/macos/TidyVNC/DocumentReviewView.swift ../../apps/macos/TidyVNC/DocumentMonitorMappingView.swift)
set_target_properties(native-document-mapping-ui-tests PROPERTIES Swift_MODULE_NAME NativeDocumentMappingUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/DocumentMappingUI-Info.plist.in)
target_compile_options(native-document-mapping-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-document-mapping-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-document-mapping-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-document-mapping-ui-tests>" VERBATIM)
add_test(NAME NativeDocuments.DisplayMappingRecovery COMMAND native-document-mapping-ui-tests --verify --output ${CMAKE_CURRENT_BINARY_DIR}/document-mapping-ui-render)
set_tests_properties(NativeDocuments.DisplayMappingRecovery PROPERTIES TIMEOUT 40)

add_executable(native-export-mapping-ui-tests MACOSX_BUNDLE NativeExportMappingUITests.swift ../../apps/macos/TidyVNC/DocumentExportView.swift)
set_target_properties(native-export-mapping-ui-tests PROPERTIES Swift_MODULE_NAME NativeExportMappingUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ExportMappingUI-Info.plist.in)
target_compile_options(native-export-mapping-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-export-mapping-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-export-mapping-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-export-mapping-ui-tests>" VERBATIM)
add_test(NAME NativeDocuments.ExportMappingAndSheetLifetime COMMAND native-export-mapping-ui-tests --verify --output ${CMAKE_CURRENT_BINARY_DIR}/export-mapping-ui-render)
set_tests_properties(NativeDocuments.ExportMappingAndSheetLifetime PROPERTIES TIMEOUT 40)

add_executable(native-defaults-mapping-ui-tests MACOSX_BUNDLE NativeDefaultsMappingUITests.swift ../../apps/macos/TidyVNC/DefaultsImportView.swift)
set_target_properties(native-defaults-mapping-ui-tests PROPERTIES Swift_MODULE_NAME NativeDefaultsMappingUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/DefaultsMappingUI-Info.plist.in)
target_compile_options(native-defaults-mapping-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-defaults-mapping-ui-tests PRIVATE tidyvnc_macos_bridge)
add_custom_command(TARGET native-defaults-mapping-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-defaults-mapping-ui-tests>" VERBATIM)
add_test(NAME NativeImport.DefaultsMappingRecovery COMMAND native-defaults-mapping-ui-tests --verify --output ${CMAKE_CURRENT_BINARY_DIR}/defaults-mapping-ui-render)
set_tests_properties(NativeImport.DefaultsMappingRecovery PROPERTIES TIMEOUT 40)

add_executable(native-invocation-tests NativeInvocationTests.swift)
set_target_properties(native-invocation-tests PROPERTIES Swift_MODULE_NAME NativeInvocationTests)
target_compile_options(native-invocation-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-invocation-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeInvocation.SyntaxOwnershipAndCatalog COMMAND native-invocation-tests)
set_tests_properties(NativeInvocation.SyntaxOwnershipAndCatalog PROPERTIES TIMEOUT 30)

add_executable(native-invocation-resolution-tests NativeInvocationResolutionTests.swift support/HistoryBacking.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-invocation-resolution-tests PROPERTIES Swift_MODULE_NAME NativeInvocationResolutionTests)
target_compile_options(native-invocation-resolution-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-invocation-resolution-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeInvocation.ResolutionAndPrecedence COMMAND native-invocation-resolution-tests)
set_tests_properties(NativeInvocation.ResolutionAndPrecedence PROPERTIES TIMEOUT 30)

add_executable(native-invocation-monitor-tests NativeInvocationMonitorTests.swift)
set_target_properties(native-invocation-monitor-tests PROPERTIES Swift_MODULE_NAME NativeInvocationMonitorTests)
target_compile_options(native-invocation-monitor-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-invocation-monitor-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeInvocation.FileMonitorPrecedenceAndRecovery COMMAND native-invocation-monitor-tests)
set_tests_properties(NativeInvocation.FileMonitorPrecedenceAndRecovery PROPERTIES TIMEOUT 30)

add_executable(native-invocation-bootstrap-tests NativeInvocationBootstrapTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-invocation-bootstrap-tests PROPERTIES Swift_MODULE_NAME NativeInvocationBootstrapTests)
target_compile_options(native-invocation-bootstrap-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-invocation-bootstrap-tests PRIVATE support)
target_link_libraries(native-invocation-bootstrap-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInvocation.StrictBootstrapAndConnection COMMAND native-invocation-bootstrap-tests)
set_tests_properties(NativeInvocation.StrictBootstrapAndConnection PROPERTIES TIMEOUT 40)

add_executable(native-invocation-launch-ui-tests MACOSX_BUNDLE NativeInvocationLaunchUITests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-invocation-launch-ui-tests PROPERTIES Swift_MODULE_NAME NativeInvocationLaunchUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/InvocationLaunch-Info.plist.in)
target_compile_options(native-invocation-launch-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-invocation-launch-ui-tests PRIVATE support)
target_link_libraries(native-invocation-launch-ui-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_custom_command(TARGET native-invocation-launch-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-invocation-launch-ui-tests>" VERBATIM)
add_test(NAME NativeInvocation.SwiftUIFirstWindowOwnership COMMAND native-invocation-launch-ui-tests -Shared)
add_test(NAME NativeInvocation.SwiftUIFileReviewOwnership COMMAND native-invocation-launch-ui-tests -Shared)
set_tests_properties(NativeInvocation.SwiftUIFileReviewOwnership PROPERTIES ENVIRONMENT "TIDYVNC_LAUNCH_FIXTURE_FILE=1")
set_tests_properties(NativeInvocation.SwiftUIFirstWindowOwnership NativeInvocation.SwiftUIFileReviewOwnership PROPERTIES TIMEOUT 40)

add_executable(native-network-policy-tests NativeNetworkPolicyTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-network-policy-tests PROPERTIES Swift_MODULE_NAME NativeNetworkPolicyTests)
target_compile_options(native-network-policy-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-network-policy-tests PRIVATE support)
target_link_libraries(native-network-policy-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInvocation.NetworkFamilyPolicyAndWire COMMAND native-network-policy-tests)
set_tests_properties(NativeInvocation.NetworkFamilyPolicyAndWire PROPERTIES TIMEOUT 40)

add_executable(native-pointer-timing-tests NativePointerTimingTests.swift)
set_target_properties(native-pointer-timing-tests PROPERTIES Swift_MODULE_NAME NativePointerTimingTests)
target_compile_options(native-pointer-timing-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-pointer-timing-tests PRIVATE support)
target_link_libraries(native-pointer-timing-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInvocation.PointerTimingAndWire COMMAND native-pointer-timing-tests)
set_tests_properties(NativeInvocation.PointerTimingAndWire PROPERTIES TIMEOUT 40)

add_executable(native-message-limits-tests NativeMessageLimitsTests.swift)
set_target_properties(native-message-limits-tests PROPERTIES Swift_MODULE_NAME NativeMessageLimitsTests)
target_compile_options(native-message-limits-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-message-limits-tests PRIVATE support)
target_link_libraries(native-message-limits-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeInvocation.ClipboardMessageLimitsAndWire COMMAND native-message-limits-tests)
set_tests_properties(NativeInvocation.ClipboardMessageLimitsAndWire PROPERTIES TIMEOUT 40)

add_executable(native-window-startup-tests NativeWindowStartupTests.swift)
set_target_properties(native-window-startup-tests PROPERTIES Swift_MODULE_NAME NativeWindowStartupTests)
target_compile_options(native-window-startup-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-window-startup-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeInvocation.InitialWindowPlacement COMMAND native-window-startup-tests)
set_tests_properties(NativeInvocation.InitialWindowPlacement PROPERTIES TIMEOUT 40)

add_executable(native-process-logging-tests NativeProcessLoggingTests.swift)
set_target_properties(native-process-logging-tests PROPERTIES Swift_MODULE_NAME NativeProcessLoggingTests)
target_compile_options(native-process-logging-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_link_libraries(native-process-logging-tests PRIVATE tidyvnc_macos_bridge)
add_test(NAME NativeInvocation.ProcessLoggingStartup COMMAND native-process-logging-tests)
set_tests_properties(NativeInvocation.ProcessLoggingStartup PROPERTIES TIMEOUT 40)

add_executable(native-password-file-tests NativePasswordFileTests.swift)
set_target_properties(native-password-file-tests PROPERTIES Swift_MODULE_NAME NativePasswordFileTests)
target_compile_options(native-password-file-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-password-file-tests PRIVATE support)
target_link_libraries(native-password-file-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCredentials.PasswordFileReaderAndReply COMMAND native-password-file-tests)
set_tests_properties(NativeCredentials.PasswordFileReaderAndReply PROPERTIES TIMEOUT 40)

add_executable(native-launch-credentials-tests NativeLaunchCredentialsTests.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-launch-credentials-tests PROPERTIES Swift_MODULE_NAME NativeLaunchCredentialsTests)
target_compile_options(native-launch-credentials-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-launch-credentials-tests PRIVATE support)
target_link_libraries(native-launch-credentials-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeCredentials.LaunchOwnershipAndPrecedence COMMAND native-launch-credentials-tests)
add_test(NAME NativeCredentials.LaunchEnvironmentCapture COMMAND native-launch-credentials-tests --capture)
set_tests_properties(NativeCredentials.LaunchOwnershipAndPrecedence NativeCredentials.LaunchEnvironmentCapture PROPERTIES TIMEOUT 40)
set_tests_properties(NativeCredentials.LaunchEnvironmentCapture PROPERTIES ENVIRONMENT "VNC_USERNAME=fixture;VNC_PASSWORD=password")

add_executable(native-listener-tests NativeListenerTests.swift)
set_target_properties(native-listener-tests PROPERTIES Swift_MODULE_NAME NativeListenerTests)
target_compile_options(native-listener-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-listener-tests PRIVATE support)
target_link_libraries(native-listener-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativeListener.CallbacksHandoffAndDrain COMMAND native-listener-tests)
set_tests_properties(NativeListener.CallbacksHandoffAndDrain PROPERTIES TIMEOUT 40)

add_executable(native-listener-ui-tests MACOSX_BUNDLE NativeListenerUITests.swift
  ../../apps/macos/TidyVNC/ListenerModel.swift ../../apps/macos/TidyVNC/ListenerView.swift
  ../../apps/macos/TidyVNC/DocumentReviewView.swift ../../apps/macos/TidyVNC/DocumentMonitorMappingView.swift
  ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-listener-ui-tests PROPERTIES Swift_MODULE_NAME NativeListenerUITests
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/ListenerUI-Info.plist.in)
target_compile_options(native-listener-ui-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-listener-ui-tests PRIVATE support)
target_link_libraries(native-listener-ui-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_custom_command(TARGET native-listener-ui-tests POST_BUILD
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:native-listener-ui-tests>" VERBATIM)
add_test(NAME NativeListener.PresentationAndConnectionRouting COMMAND native-listener-ui-tests)
set_tests_properties(NativeListener.PresentationAndConnectionRouting PROPERTIES TIMEOUT 45)

add_executable(native-tunnel-child support/tunnel-child.c)
add_executable(native-tunnel-tests NativeTunnelTests.swift)
set_target_properties(native-tunnel-tests PROPERTIES Swift_MODULE_NAME NativeTunnelTests)
target_compile_options(native-tunnel-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-tunnel-tests PRIVATE support)
target_link_libraries(native-tunnel-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_dependencies(native-tunnel-tests native-tunnel-child)
add_test(NAME NativeTunnel.ProcessOwnershipAndForwarding COMMAND native-tunnel-tests $<TARGET_FILE:native-tunnel-child>)
set_tests_properties(NativeTunnel.ProcessOwnershipAndForwarding PROPERTIES TIMEOUT 40)
find_package(Python3 QUIET COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
  add_test(NAME NativeTunnel.IsolatedOpenSSH
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tunnel-ssh.py $<TARGET_FILE:native-tunnel-tests>)
  set_tests_properties(NativeTunnel.IsolatedOpenSSH PROPERTIES TIMEOUT 45 SKIP_RETURN_CODE 77)
endif()

add_executable(native-tunnel-controller-tests NativeTunnelControllerTests.swift support/TrustFixtures.swift ../../apps/macos/TidyVNC/ConnectionModel.swift)
set_target_properties(native-tunnel-controller-tests PROPERTIES Swift_MODULE_NAME NativeTunnelControllerTests)
target_compile_options(native-tunnel-controller-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-tunnel-controller-tests PRIVATE support)
target_link_libraries(native-tunnel-controller-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_dependencies(native-tunnel-controller-tests native-tunnel-child)
add_test(NAME NativeTunnel.ConnectionControllerLifecycle COMMAND native-tunnel-controller-tests $<TARGET_FILE:native-tunnel-child>)
set_tests_properties(NativeTunnel.ConnectionControllerLifecycle PROPERTIES TIMEOUT 60)
if(Python3_Interpreter_FOUND)
  add_test(NAME NativeTunnel.ConnectionControllerOpenSSH
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tunnel-ssh.py $<TARGET_FILE:native-tunnel-controller-tests>)
  set_tests_properties(NativeTunnel.ConnectionControllerOpenSSH PROPERTIES TIMEOUT 45 SKIP_RETURN_CODE 77)
endif()

add_executable(native-ssh-askpass-tests NativeSSHAskpassTests.swift ../../apps/macos/TidyVNC/SSHAuthenticationSheet.swift)
set_target_properties(native-ssh-askpass-tests PROPERTIES Swift_MODULE_NAME NativeSSHAskpassTests)
target_compile_options(native-ssh-askpass-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-ssh-askpass-tests PRIVATE support)
target_link_libraries(native-ssh-askpass-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_dependencies(native-ssh-askpass-tests tidyvnc-ssh-askpass)
add_test(NAME NativeTunnel.AskpassTransportAndInteraction COMMAND native-ssh-askpass-tests $<TARGET_FILE:tidyvnc-ssh-askpass>)
set_tests_properties(NativeTunnel.AskpassTransportAndInteraction PROPERTIES TIMEOUT 40)
if(Python3_Interpreter_FOUND)
  add_test(NAME NativeTunnel.AskpassOpenSSH
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tunnel-ssh.py $<TARGET_FILE:native-ssh-askpass-tests> $<TARGET_FILE:tidyvnc-ssh-askpass>)
  set_tests_properties(NativeTunnel.AskpassOpenSSH PROPERTIES TIMEOUT 45 SKIP_RETURN_CODE 77)
endif()

if(Python3_Interpreter_FOUND)
  foreach(algorithm rsa ecdsa)
    add_test(NAME NativeTunnel.HostKey-${algorithm}
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tunnel-ssh.py $<TARGET_FILE:native-ssh-askpass-tests> $<TARGET_FILE:tidyvnc-ssh-askpass> ${algorithm})
    set_tests_properties(NativeTunnel.HostKey-${algorithm} PROPERTIES TIMEOUT 45 SKIP_RETURN_CODE 77)
  endforeach()
endif()

add_executable(native-presentation-issue-tests NativePresentationIssueTests.swift)
set_target_properties(native-presentation-issue-tests PROPERTIES Swift_MODULE_NAME NativePresentationIssueTests)
target_compile_options(native-presentation-issue-tests PRIVATE -swift-version 6 -strict-concurrency=complete
  -warnings-as-errors -parse-as-library -module-cache-path ${CMAKE_CURRENT_BINARY_DIR}/module-cache)
target_include_directories(native-presentation-issue-tests PRIVATE support)
target_link_libraries(native-presentation-issue-tests PRIVATE tidyvnc_macos_bridge native-test-peer)
add_test(NAME NativePresentation.StructuredRecoveryAndRedaction COMMAND native-presentation-issue-tests)
set_tests_properties(NativePresentation.StructuredRecoveryAndRedaction PROPERTIES TIMEOUT 40)

if(Python3_Interpreter_FOUND)
  add_test(NAME NativeLocalization.CompilerCatalogAudit
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/localization-source-tests.py)
  set_tests_properties(NativeLocalization.CompilerCatalogAudit PROPERTIES TIMEOUT 10)
endif()
