/* MSVC compatibility for the portable core (plans/native-ui-winui/CORE.md
 * section 2). Force-included into every MSVC and clang-cl translation unit so
 * the shared POSIX-flavoured sources compile unchanged; GCC, Clang and MinGW
 * builds never see this file. Keep it limited to spellings; behaviour that
 * differs on Windows belongs in the platform adapters. */
#ifndef TIDYVNC_MSVC_COMPAT_H
#define TIDYVNC_MSVC_COMPAT_H

#if defined(_MSC_VER)

/* GCC attributes (format checks, warn_unused_result) have no MSVC spelling
 * with the same placement; MinGW and the other toolchains keep checking them. */
#if !defined(__clang__)
#define __attribute__(x)
#endif

#include <basetsd.h>
#include <direct.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#ifndef TIDYVNC_HAVE_SSIZE_T
#define TIDYVNC_HAVE_SSIZE_T 1
typedef SSIZE_T ssize_t;
#endif

#ifndef TIDYVNC_HAVE_MODE_T
#define TIDYVNC_HAVE_MODE_T 1
/* MinGW's spelling; mkdir() ignores it on Windows. */
typedef unsigned short mode_t;
#endif

#ifndef PATH_MAX
/* Matches MinGW's value; long paths are handled by the Windows adapters. */
#define PATH_MAX 260
#endif

#ifndef strcasecmp
#define strcasecmp _stricmp
#endif
#ifndef strncasecmp
#define strncasecmp _strnicmp
#endif

#endif /* _MSC_VER */
#endif /* TIDYVNC_MSVC_COMPAT_H */
