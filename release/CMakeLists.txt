if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  message(FATAL_ERROR "cmake must be invoked with the top level directory")
endif()

#
# Windows installer (Inno Setup)
#

if(WIN32)

if(CMAKE_SIZEOF_VOID_P MATCHES 8)
  set(INST_SUFFIX 64)
  set(INST_DEFS -DWIN64)
endif()

configure_file(tigervnc.iss.in tigervnc.iss)

add_custom_command(OUTPUT ${CMAKE_PROJECT_NAME}${INST_SUFFIX}-${VERSION}.exe
  COMMAND iscc -o. ${INST_DEFS} -F${CMAKE_PROJECT_NAME}${INST_SUFFIX}-${VERSION} tigervnc.iss
  DEPENDS vncviewer tigervnc.iss)
add_custom_target(installer DEPENDS ${CMAKE_PROJECT_NAME}${INST_SUFFIX}-${VERSION}.exe)

if(BUILD_WINVNC)
  configure_file(winvnc.iss.in winvnc.iss)

  add_custom_command(OUTPUT ${CMAKE_PROJECT_NAME}${INST_SUFFIX}-winvnc-${VERSION}.exe
    COMMAND iscc -o. ${INST_DEFS} -F${CMAKE_PROJECT_NAME}${INST_SUFFIX}-winvnc-${VERSION} winvnc.iss
    DEPENDS winvnc4 wm_hooks vncconfig winvnc.iss)
  add_custom_target(winvnc_installer DEPENDS ${CMAKE_PROJECT_NAME}${INST_SUFFIX}-winvnc-${VERSION}.exe)
endif()

endif() # WIN32


#
# Mac DMG
#

if(APPLE)

set(MACAPP_LANGUAGES "")
set(MACAPP_CATALOGS "")
if(ENABLE_NLS)
  file(STRINGS "${CMAKE_SOURCE_DIR}/po/LINGUAS" MACAPP_LANGUAGES)
  foreach(lang ${MACAPP_LANGUAGES})
    list(APPEND MACAPP_CATALOGS "${CMAKE_BINARY_DIR}/po/${lang}.mo")
  endforeach()
  string(REPLACE ";" " " MACAPP_LANGUAGES "${MACAPP_LANGUAGES}")
endif()
configure_file(makemacapp.in makemacapp @ONLY)
configure_file(Info.plist.in Info.plist @ONLY)
set(MACAPP_INPUTS vncviewer makemacapp Info.plist ${MACAPP_CATALOGS}
  "${CMAKE_SOURCE_DIR}/media/icons/tidyvnc.icns"
  "${CMAKE_SOURCE_DIR}/README.rst" "${CMAKE_SOURCE_DIR}/LICENCE.TXT")
add_custom_target(macapp
  COMMAND sh makemacapp --stage-only
  DEPENDS ${MACAPP_INPUTS}
  VERBATIM)
add_custom_command(OUTPUT TidyVNC-${VERSION}.dmg
  COMMAND sh makemacapp
  DEPENDS ${MACAPP_INPUTS}
  VERBATIM)
add_custom_target(dmg DEPENDS TidyVNC-${VERSION}.dmg)
add_dependencies(macapp icons)
add_dependencies(dmg icons)
if(ENABLE_NLS)
  add_dependencies(macapp translations)
  add_dependencies(dmg translations)
endif()

endif() # APPLE


#
# Binary tarball
#

if(UNIX AND NOT APPLE)

configure_file(maketarball.in maketarball)

if(BUILD_JAVA)
  set(TARBALL_JAVA_DEPENDENCY java)
endif()

set(PACKAGE_FILE ${CMAKE_PROJECT_NAME}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}-${VERSION}.tar.gz)
add_custom_command(OUTPUT ${PACKAGE_FILE}
  COMMAND bash maketarball
  DEPENDS maketarball vncviewer vncpasswd vncconfig ${TARBALL_JAVA_DEPENDENCY})

add_custom_target(tarball DEPENDS ${PACKAGE_FILE})

endif() #UNIX

#
# Common
#

install(FILES ${CMAKE_SOURCE_DIR}/LICENCE.TXT DESTINATION ${CMAKE_INSTALL_FULL_DOCDIR})
install(FILES ${CMAKE_SOURCE_DIR}/README.rst DESTINATION ${CMAKE_INSTALL_FULL_DOCDIR})
