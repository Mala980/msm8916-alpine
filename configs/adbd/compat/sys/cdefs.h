#ifndef _COMPAT_SYS_CDEFS_H
#define _COMPAT_SYS_CDEFS_H
/* Minimal musl replacement for the glibc <sys/cdefs.h> bits this
   codebase uses (only __BEGIN_DECLS/__END_DECLS in practice). */
#ifdef __cplusplus
# define __BEGIN_DECLS extern "C" {
# define __END_DECLS }
#else
# define __BEGIN_DECLS
# define __END_DECLS
#endif
#ifndef __P
# define __P(args) args
#endif
#endif
