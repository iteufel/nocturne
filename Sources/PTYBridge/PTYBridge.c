#include "PTYBridge.h"
#include <util.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <fcntl.h>

pid_t nocturne_pty_spawn(int *master, const char *home, const char *user, unsigned short columns, unsigned short rows) {
    // Prepare all allocations before fork. The child executes only async-signal-safe functions.
    char *homeEnv = NULL, *userEnv = NULL;
    if (asprintf(&homeEnv, "HOME=%s", home) < 0 || asprintf(&userEnv, "USER=%s", user) < 0) {
        free(homeEnv); free(userEnv); return -1;
    }
    char *args[] = {"/bin/zsh", "-l", NULL};
    char *env[] = {homeEnv, userEnv, "TERM=xterm-256color", "COLORTERM=truecolor", "SHELL=/bin/zsh",
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", NULL};
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    struct rlimit limit; getrlimit(RLIMIT_NOFILE, &limit);
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        if (chdir(home) != 0) _exit(126);
        for (int fd = 3; fd < (int)limit.rlim_cur; fd++) close(fd);
        execve(args[0], args, env);
        _exit(127);
    }
    free(homeEnv); free(userEnv);
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}
int nocturne_pty_resize(int master, unsigned short columns, unsigned short rows) {
    struct winsize size = {.ws_col = columns, .ws_row = rows};
    return ioctl(master, TIOCSWINSZ, &size);
}
void nocturne_pty_terminate(pid_t pid) {
    if (pid <= 0) return;
    kill(-pid, SIGHUP);
    kill(pid, SIGTERM);
}
