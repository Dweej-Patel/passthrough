#include "CPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

// posix_spawn can't do this: on macOS a session only gains a controlling
// terminal through TIOCSCTTY, and without one the tty has no foreground
// process group, so ctrl-C reaches nothing. Between fork and exec the child
// calls only async-signal-safe functions, so forking a threaded app is fine.
pid_t pt_spawn_on_pty(const char *path, char *const argv[], char *const envp[],
                      int slave, const char *directory) {
    int report[2];   // the child writes errno here if it can't exec
    if (pipe(report) != 0) return -1;
    fcntl(report[0], F_SETFD, FD_CLOEXEC);
    fcntl(report[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        int error = errno;
        close(report[0]); close(report[1]);
        errno = error;
        return -1;
    }
    if (pid == 0) {
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        struct sigaction dfl = { 0 };
        dfl.sa_handler = SIG_DFL;
        for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &dfl, NULL);

        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0
            || dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0
            || chdir(directory) < 0) goto fail;
        for (int fd = 3, max = getdtablesize(); fd < max; fd++) {
            if (fd != report[1]) close(fd);
        }
        execve(path, argv, envp);
    fail:;
        int error = errno;
        write(report[1], &error, sizeof error);
        _exit(127);
    }

    close(report[1]);
    int error = 0;
    ssize_t n;
    do { n = read(report[0], &error, sizeof error); } while (n < 0 && errno == EINTR);
    close(report[0]);
    if (n == sizeof error) {   // exec failed: reap the child and report why
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        errno = error;
        return -1;
    }
    return pid;
}
