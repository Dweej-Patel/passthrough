#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Starts `path` in a new session whose controlling terminal is the pty slave
/// `slave`, on descriptors 0-2, in `directory`, with every signal at its default
/// and unblocked. Other descriptors are not inherited. Returns the pid, or -1
/// with errno set (also when exec fails in the child).
pid_t pt_spawn_on_pty(const char *path, char *const argv[], char *const envp[],
                      int slave, const char *directory);

#endif
