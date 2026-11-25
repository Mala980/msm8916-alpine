#ifndef _COMPAT_COMPAT_H
#define _COMPAT_COMPAT_H
#include <sys/types.h>
#include <linux/capability.h>

/* musl's <resolv.h> does not declare b64_pton (the implementation
   already lives in core/adbd/base64.c). */
int b64_pton(const char *src, u_char *dst, size_t dstsize);

/* glibc declares prctl() via <sys/prctl.h> and capset() via libcap's
   <sys/capability.h>; adb.c includes only the kernel headers and
   relied on transitive declarations. Declare both here; capset() is
   implemented in capset.c on top of the raw syscall. */
int prctl(int option, ...);
int capset(cap_user_header_t hdrp, cap_user_data_t datap);
#endif
