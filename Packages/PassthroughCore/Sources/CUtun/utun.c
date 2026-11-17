#include "CUtun.h"
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>

// From <sys/kern_control.h>, which the iOS SDK leaves out.
#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif
#define PT_CTLIOCGINFO 0xc0644e03UL   // _IOWR('N', 3, struct pt_ctl_info)

struct pt_ctl_info {
    u_int32_t ctl_id;
    char ctl_name[96];
};

struct pt_sockaddr_ctl {
    u_char sc_len;
    u_char sc_family;
    u_int16_t ss_sysaddr;
    u_int32_t sc_id;
    u_int32_t sc_unit;
    u_int32_t sc_reserved[5];
};

int passthrough_utun_fd(void) {
    struct pt_ctl_info info;
    memset(&info, 0, sizeof info);
    strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof info.ctl_name - 1);
    for (int fd = 0; fd <= 1024; fd++) {
        struct pt_sockaddr_ctl addr;
        socklen_t length = sizeof addr;
        memset(&addr, 0, sizeof addr);
        if (getpeername(fd, (struct sockaddr *)&addr, &length) != 0 || addr.sc_family != AF_SYSTEM) continue;
        if (info.ctl_id == 0 && ioctl(fd, PT_CTLIOCGINFO, &info) != 0) continue;
        if (addr.sc_id == info.ctl_id) return fd;
    }
    return -1;
}
