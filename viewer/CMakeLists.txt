# Dependency direction: frontend -> viewer_core -> viewer_platform / RFB.
add_library(tidyvnc_viewer_platform STATIC platform/DisplayMetrics.cxx)
target_include_directories(tidyvnc_viewer_platform PUBLIC ${CMAKE_SOURCE_DIR})

add_library(tidyvnc_viewer_core STATIC
  core/FramePublisher.cxx
  core/ProtocolSession.cxx
  core/DesktopTransform.cxx
  core/DesktopLayout.cxx
  core/DesktopResampler.cxx
  core/DesktopTileCache.cxx
  core/CursorRenderer.cxx)
target_include_directories(tidyvnc_viewer_core PUBLIC ${CMAKE_SOURCE_DIR})
target_link_libraries(tidyvnc_viewer_core PUBLIC
  tidyvnc_viewer_platform rfbclient network)
