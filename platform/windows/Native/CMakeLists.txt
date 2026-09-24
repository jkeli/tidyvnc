# tidyvnc_windows.dll: the WinUI frontend's native helper (plans/native-ui-winui
# DECISIONS.md D1, TODO W3.4). Presenter, keyboard translation and hooks,
# cursors and display topology behind the C API in tidyvnc_windows.h. It does
# not link the core; TidyVNC.Native calls both DLLs.

# The translator is a static library so the equivalence test can drive it
# with a scripted keyboard system.
add_library(tidyvnc_windows_keyboard STATIC
  KeyboardTranslator.cxx
  ${CMAKE_SOURCE_DIR}/vncviewer/keysym2ucs.c)
target_include_directories(tidyvnc_windows_keyboard
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}
  PRIVATE ${CMAKE_SOURCE_DIR}/common ${CMAKE_SOURCE_DIR}/vncviewer)
target_compile_definitions(tidyvnc_windows_keyboard PUBLIC UNICODE _UNICODE)
target_link_libraries(tidyvnc_windows_keyboard PUBLIC user32)

add_library(tidyvnc_windows SHARED
  Keyboard.cxx
  KeyboardHooks.cxx
  Presenter.cxx
  Cursor.cxx
  Displays.cxx
  tidyvnc_windows.h)
target_compile_definitions(tidyvnc_windows PRIVATE TIDYVNC_WINDOWS_BUILDING)
target_include_directories(tidyvnc_windows PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(tidyvnc_windows PRIVATE tidyvnc_windows_keyboard
  d3d11 dxgi user32 gdi32 bcrypt shcore)
