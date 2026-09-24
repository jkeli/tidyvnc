enable_testing()
find_package(Python3 QUIET COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
  add_test(NAME ViewerBuild.FrontendSelection
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/frontend-options.py)
endif()
add_executable(viewer-core-smoke core-smoke.cxx)
target_link_libraries(viewer-core-smoke PRIVATE tidyvnc_viewer_core)
add_test(NAME ViewerCore.HeadlessConsumer COMMAND viewer-core-smoke)

add_executable(viewer-c-abi-smoke c-abi-smoke.c c-abi-test-support.cxx)
target_link_libraries(viewer-c-abi-smoke PRIVATE tidyvnc_viewer_c)
add_test(NAME ViewerABI.PureCConsumer COMMAND viewer-c-abi-smoke)
set_tests_properties(ViewerABI.PureCConsumer PROPERTIES TIMEOUT 60)

# Windows: the same C smoke through tidyvnc_viewer.dll's import library, the
# DLL's export list against the header, and run-time loading as .NET does.
if(TARGET tidyvnc_viewer_shared)
  add_executable(viewer-c-abi-dll-smoke c-abi-smoke.c c-abi-test-support.cxx)
  target_link_libraries(viewer-c-abi-dll-smoke PRIVATE tidyvnc_viewer_shared)
  add_test(NAME ViewerABI.PureCConsumerThroughDLL COMMAND viewer-c-abi-dll-smoke)
  set_tests_properties(ViewerABI.PureCConsumerThroughDLL PROPERTIES TIMEOUT 60)
  add_executable(viewer-c-abi-dll-load c-abi-dll-load.c)
  target_include_directories(viewer-c-abi-dll-load PRIVATE ${CMAKE_SOURCE_DIR}/viewer/bridge)
  add_dependencies(viewer-c-abi-dll-load tidyvnc_viewer_shared)
  add_test(NAME ViewerABI.DLLLoadsAtRunTime
    COMMAND viewer-c-abi-dll-load $<TARGET_FILE:tidyvnc_viewer_shared>)
  if(GNUTLS_FOUND)
    # W1.13: VncAuth and X509Vnc sessions end to end through the DLL only.
    add_executable(viewer-dll-end-to-end dll-end-to-end.cxx)
    target_link_libraries(viewer-dll-end-to-end PRIVATE tidyvnc_viewer_shared rfb rdr network ws2_32)
    target_include_directories(viewer-dll-end-to-end SYSTEM PRIVATE ${GNUTLS_INCLUDE_DIR})
    add_test(NAME ViewerABI.EndToEndThroughDLL COMMAND viewer-dll-end-to-end)
    set_tests_properties(ViewerABI.EndToEndThroughDLL PROPERTIES TIMEOUT 90)
  endif()
  get_filename_component(TIDYVNC_LINKER_DIR "${CMAKE_LINKER}" DIRECTORY)
  find_program(TIDYVNC_DUMPBIN dumpbin HINTS "${TIDYVNC_LINKER_DIR}")
  if(Python3_Interpreter_FOUND AND TIDYVNC_DUMPBIN)
    add_test(NAME ViewerABI.DLLExportsMatchHeader
      COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/dll-exports.py
        ${CMAKE_SOURCE_DIR}/viewer/bridge/tidyvnc.h $<TARGET_FILE:tidyvnc_viewer_shared> ${TIDYVNC_DUMPBIN})
  endif()
endif()
