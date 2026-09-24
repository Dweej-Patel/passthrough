#ifndef CRESOLV_H
#define CRESOLV_H

/// Writes the DNS servers the system resolver currently uses into `out` as
/// numeric addresses separated by commas (e.g. "192.168.1.1,fd00::1").
/// Returns how many were written; 0 when none are known.
int pt_system_dns_servers(char *out, int out_len);

#endif
