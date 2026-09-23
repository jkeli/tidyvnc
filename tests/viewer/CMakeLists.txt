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
