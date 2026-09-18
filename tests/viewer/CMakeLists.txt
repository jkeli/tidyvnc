enable_testing()
add_executable(viewer-core-smoke core-smoke.cxx)
target_link_libraries(viewer-core-smoke PRIVATE tidyvnc_viewer_core)
add_test(NAME ViewerCore.HeadlessConsumer COMMAND viewer-core-smoke)
