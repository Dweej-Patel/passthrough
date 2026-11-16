#ifndef CUTUN_H
#define CUTUN_H

/// The file descriptor of this process's utun (a packet tunnel extension's
/// tunnel), found by scanning open descriptors for a kernel-control socket
/// connected to com.apple.net.utun_control. -1 when there is none.
/// NEPacketTunnelFlow doesn't expose it; tun2socks needs it to read and
/// write packets itself.
int passthrough_utun_fd(void);

#endif
