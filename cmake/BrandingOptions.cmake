# Keep existing build invocations usable without overriding a new explicit value.
if(DEFINED TIGERVNC_FLTK_SHARED)
  message(DEPRECATION "TIGERVNC_FLTK_SHARED is deprecated; use TIDYVNC_FLTK_SHARED")
  if(DEFINED TIDYVNC_FLTK_SHARED)
    if((TIGERVNC_FLTK_SHARED AND NOT TIDYVNC_FLTK_SHARED) OR
       (TIDYVNC_FLTK_SHARED AND NOT TIGERVNC_FLTK_SHARED))
      message(FATAL_ERROR "Conflicting TIGERVNC_FLTK_SHARED and TIDYVNC_FLTK_SHARED; remove the legacy cache entry or give both the same value")
    endif()
  else()
    set(TIDYVNC_FLTK_SHARED "${TIGERVNC_FLTK_SHARED}" CACHE BOOL "Use shared FLTK libraries")
  endif()
endif()
option(TIDYVNC_FLTK_SHARED "Use shared FLTK libraries" OFF)
