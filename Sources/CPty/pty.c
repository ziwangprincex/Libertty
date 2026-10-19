#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

pid_t libertty_pty_spawn(const char *path,
                      char *const argv[],
                      char *const envp[],
                      const char *cwd,
                      uint16_t cols, uint16_t rows,
                      uint16_t width_px, uint16_t height_px,
                      int *master_out) {
    struct winsize ws = {
        .ws_row = rows, .ws_col = cols,
        .ws_xpixel = width_px, .ws_ypixel = height_px,
    };
    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) return -1;

    // Canonical-mode line editing erases whole UTF-8 characters (as Tern does).
    struct termios t;
    if (tcgetattr(slave, &t) == 0) {
        t.c_iflag |= IUTF8;
        tcsetattr(slave, TCSANOW, &t);
    }

    // The parent keeps only the master; neither end may leak into other children.
    fcntl(master, F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(master);
        close(slave);
        errno = saved;
        return -1;
    }

    if (pid == 0) {
        // Child: only async-signal-safe calls from here to execve.
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        close(master);

        // The app may have ignored or blocked signals; the shell expects defaults.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);

        if (cwd) chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    close(slave);
    // Non-blocking: the reader spins briefly on EAGAIN instead of sleeping in
    // read() for every ~1 KiB the kernel hands out (see PTYReader).
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    *master_out = master;
    return pid;
}

int libertty_pty_resize(int master, uint16_t cols, uint16_t rows,
                     uint16_t width_px, uint16_t height_px) {
    struct winsize ws = {
        .ws_row = rows, .ws_col = cols,
        .ws_xpixel = width_px, .ws_ypixel = height_px,
    };
    return ioctl(master, TIOCSWINSZ, &ws);
}

pid_t libertty_pty_foreground_pgid(int master) {
    return tcgetpgrp(master);
}
