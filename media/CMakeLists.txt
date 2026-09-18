# Ordinary/offline builds consume reviewed assets without requiring graphics tools.
set(LINUX_ICON_SIZES 16 22 24 32 48 64 128 256 512)
set(ICON_FILES "${CMAKE_CURRENT_SOURCE_DIR}/icons/tidyvnc.svg"
               "${CMAKE_CURRENT_SOURCE_DIR}/icons/tidyvnc.ico"
               "${CMAKE_CURRENT_SOURCE_DIR}/icons/tidyvnc.icns")
foreach(size ${LINUX_ICON_SIZES})
  list(APPEND ICON_FILES "${CMAKE_CURRENT_SOURCE_DIR}/icons/tidyvnc_${size}.png")
endforeach()
foreach(icon ${ICON_FILES})
  if(NOT EXISTS "${icon}")
    message(FATAL_ERROR "Missing reviewed TidyVNC asset: ${icon}; see media/README.md")
  endif()
endforeach()
add_custom_target(icons DEPENDS ${ICON_FILES})

# Opt-in generation into the build tree only. Qt/Pillow are optional developer tools.
option(TIDYVNC_REGENERATE_ICONS "Enable icon regeneration (Qt6, Python Pillow, iconutil)" OFF)
if(TIDYVNC_REGENERATE_ICONS)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_subdirectory(tools)
  set(EXPORT_DIR "${CMAKE_CURRENT_BINARY_DIR}/export")
  add_custom_target(icons_regenerate
    COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tools/export-icons.py"
      --renderer $<TARGET_FILE:render-svg> --output "${EXPORT_DIR}"
    DEPENDS render-svg tidyvnc.svg tidyvnc-small.svg tools/export-icons.py
    VERBATIM)
  add_custom_target(icons_verify
    COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tools/export-icons.py"
      --renderer $<TARGET_FILE:render-svg> --output "${EXPORT_DIR}" --verify
    DEPENDS render-svg tidyvnc.svg tidyvnc-small.svg tools/export-icons.py ${ICON_FILES}
    VERBATIM)
endif()
