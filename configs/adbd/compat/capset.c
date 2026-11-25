/* capset(2) wrapper for musl, which (unlike glibc+libcap) does not
   declare or provide it. */
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/capability.h>

int capset(cap_user_header_t hdrp, cap_user_data_t datap)
{
    return (int)syscall(SYS_capset, hdrp, datap);
}
