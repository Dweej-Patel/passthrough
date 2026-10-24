#include "CResolv.h"
#include <netdb.h>
#include <resolv.h>
#include <string.h>
#include <sys/socket.h>

int pt_system_dns_servers(char *out, int out_len) {
    if (out == NULL || out_len <= 0) return 0;
    out[0] = '\0';
    struct __res_state state;
    memset(&state, 0, sizeof state);
    // res_ninit can fail after allocating (BIND's res_vinit records a failed
    // allocation and still returns an error), and only res_ndestroy frees what
    // it allocated. res_ndestroy also closes `_vcsock` when it is >= 0, so mark
    // it unused first: a failure before res_ninit sets it must not close fd 0.
    // Its other frees are NULL-checked, and it clears what it freed, so this
    // never frees twice.
    state._vcsock = -1;
    if (res_ninit(&state) != 0) {
        res_ndestroy(&state);
        return 0;
    }
    union res_sockaddr_union servers[8];
    int n = res_getservers(&state, servers, 8);
    int count = 0;
    size_t used = 0;
    for (int i = 0; i < n; i++) {
        struct sockaddr *sa = (struct sockaddr *)&servers[i];
        socklen_t len = sa->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
        char host[NI_MAXHOST];
        if (getnameinfo(sa, len, host, sizeof host, NULL, 0, NI_NUMERICHOST) != 0) continue;
        size_t need = strlen(host) + (count > 0 ? 1 : 0);
        if (used + need + 1 > (size_t)out_len) break;
        if (count > 0) out[used++] = ',';
        memcpy(out + used, host, strlen(host));
        used += strlen(host);
        out[used] = '\0';
        count++;
    }
    res_ndestroy(&state);
    return count;
}
