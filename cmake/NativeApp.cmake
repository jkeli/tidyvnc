set(TIDYVNC_NATIVE_APP_BUILD_DIR "${CMAKE_BINARY_DIR}/native-app" CACHE PATH
  "Separate generated Xcode app build directory")
get_filename_component(native_app_build "${TIDYVNC_NATIVE_APP_BUILD_DIR}" ABSOLUTE
  BASE_DIR "${CMAKE_BINARY_DIR}")
if(native_app_build STREQUAL CMAKE_BINARY_DIR OR native_app_build STREQUAL CMAKE_SOURCE_DIR)
  message(FATAL_ERROR "TIDYVNC_NATIVE_APP_BUILD_DIR must be separate from the core build and source directories")
endif()

# Always ask Xcode to update its graph: this preserves incremental app/resource
# dependencies without hand-maintaining a second source list in the root build.
# Core dependencies are already built by Ninja; never recursively build this tree.
add_custom_target(vncviewer ALL
  COMMAND ${CMAKE_COMMAND} -E env "DEVELOPER_DIR=${native_developer_dir}"
    ${CMAKE_COMMAND} -S "${CMAKE_SOURCE_DIR}/apps/macos" -B "${native_app_build}" -G Xcode
    "-DNATIVE_CORE_BUILD=${CMAKE_BINARY_DIR}"
    "-DCMAKE_OSX_SYSROOT=${CMAKE_OSX_SYSROOT}"
    "-DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
  COMMAND ${CMAKE_COMMAND} -E env "DEVELOPER_DIR=${native_developer_dir}"
    /usr/bin/xcrun xcodebuild -project "${native_app_build}/TidyVNCNativeApp.xcodeproj"
    -scheme TidyVNC -configuration "${CMAKE_BUILD_TYPE}"
    -derivedDataPath "${native_app_build}/DerivedData" build
  COMMAND ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/tests/macos/localization-source.py"
    "${CMAKE_SOURCE_DIR}/apps/macos/Localizable.xcstrings"
    --module "${CMAKE_BINARY_DIR}/platform/macos/LocalizationSources.txt"
      "${CMAKE_BINARY_DIR}/platform/macos/localization"
    --module "${native_app_build}/LocalizationSources.txt"
      "${native_app_build}/build/TidyVNC.build/${CMAKE_BUILD_TYPE}"
  DEPENDS tidyvnc_macos_bridge tidyvnc-ssh-askpass
  USES_TERMINAL VERBATIM)
add_custom_target(macapp DEPENDS vncviewer)
message(STATUS "SwiftUI app: ${native_app_build}/${CMAKE_BUILD_TYPE}/TidyVNC.app (development signing)")
