/* MSVC stand-in for <sys/time.h>: struct timeval and gettimeofday(), as
 * MinGW provides them. See tidyvnc_msvc_compat.h. */
#ifndef TIDYVNC_MSVC_SYS_TIME_H
#define TIDYVNC_MSVC_SYS_TIME_H

#include <winsock2.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static __inline int gettimeofday(struct timeval* tv, void* tz)
{
  FILETIME ft;
  uint64_t t;
  (void)tz;
  if (tv == NULL)
    return 0;
  GetSystemTimePreciseAsFileTime(&ft);
  t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  t -= 116444736000000000ULL; /* 1601-01-01 to 1970-01-01 in 100 ns */
  tv->tv_sec = (long)(t / 10000000ULL);
  tv->tv_usec = (long)((t % 10000000ULL) / 10ULL);
  return 0;
}

#ifdef __cplusplus
}
#endif

#endif
