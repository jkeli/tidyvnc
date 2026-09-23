/* MSVC stand-in for <unistd.h>: the CRT's POSIX-named IO functions, as MinGW
 * exposes them. See tidyvnc_msvc_compat.h. */
#ifndef TIDYVNC_MSVC_UNISTD_H
#define TIDYVNC_MSVC_UNISTD_H

#include <io.h>
#include <process.h>
#include <direct.h>

#ifndef R_OK
#define R_OK 4
#define W_OK 2
#define F_OK 0
#endif

#endif
