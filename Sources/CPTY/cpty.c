#include "cpty.h"

#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], int stdin_fd, int stderr_fd,
                 unsigned short columns, int *master) {
    struct winsize size = { .ws_row = 24, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid != 0) return pid;

    // The child of a multithreaded process: only async-signal-safe calls until execve.
    dup2(stdin_fd, STDIN_FILENO);
    dup2(stderr_fd, STDERR_FILENO);
    int limit = getdtablesize();
    if (limit < 0 || limit > 65536) limit = 65536;
    for (int fd = STDERR_FILENO + 1; fd < limit; fd++) close(fd);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
    execve(path, argv, envp);
    _exit(127);
}
