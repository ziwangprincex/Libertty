#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "cpty.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int fill_address(struct sockaddr_un *addr, const char *path) {
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    strcpy(addr->sun_path, path);
    return 0;
}

int libertty_sock_listen(const char *path) {
    struct sockaddr_un addr;
    if (fill_address(&addr, path) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    unlink(path);
    // Only the owner may connect (the directory is 0700 as well).
    mode_t old = umask(077);
    int ok = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    umask(old);
    if (ok != 0 || listen(fd, 64) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int libertty_sock_connect(const char *path) {
    struct sockaddr_un addr;
    if (fill_address(&addr, path) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int nosigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int libertty_sock_accept(int listener) {
    int fd;
    do { fd = accept(listener, NULL, NULL); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int nosigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif
    // Another user's process could only get here through a misconfigured
    // directory; refuse it anyway.
#ifdef __linux__
    struct ucred cred;
    socklen_t length = sizeof(cred);
    int peer_ok = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) == 0 && cred.uid == getuid();
#else
    uid_t uid;
    gid_t gid;
    int peer_ok = getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
#endif
    if (!peer_ok) {
        close(fd);
        errno = EPERM;
        return -1;
    }
    return fd;
}

int libertty_sock_send_fd(int sock, int fd) {
    char byte = 'F';
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr msg = {
        .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof(control),
    };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));
    ssize_t n;
    do { n = sendmsg(sock, &msg, 0); } while (n < 0 && errno == EINTR);
    return n == 1 ? 0 : -1;
}

int libertty_sock_recv_fd(int sock) {
    char byte;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {
        .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof(control),
    };
    ssize_t n;
    do { n = recvmsg(sock, &msg, 0); } while (n < 0 && errno == EINTR);
    if (n != 1) return -1;
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) {
        errno = EBADMSG;
        return -1;
    }
    int fd;
    memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

#ifdef __linux__
// No POSIX_SPAWN_CLOEXEC_DEFAULT here: fork, start a session, close what
// isn't ours to pass on, exec.
pid_t libertty_spawn_detached(const char *path, char *const argv[], char *const envp[], const char *log_path) {
    int out = open(log_path ? log_path : "/dev/null", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    int in = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (out < 0 || in < 0) return -1;
    long max = sysconf(_SC_OPEN_MAX);
    if (max < 0 || max > 65536) max = 65536;
    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        close(out);
        close(in);
        errno = saved;
        return -1;
    }
    if (pid == 0) {
        setsid();
        dup2(in, STDIN_FILENO);
        dup2(out, STDOUT_FILENO);
        dup2(out, STDERR_FILENO);
        for (long fd = 3; fd < max; fd++) close((int)fd);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        execve(path, argv, envp);
        _exit(127);
    }
    close(out);
    close(in);
    return pid;
}
#else
// macOS asks the user about a program's camera, microphone, contacts and so
// on in the name of the process it holds responsible for it, which a child
// inherits. liberttyd outlives whoever started it — this app, or a shell of
// another terminal running `libertty +new-session` — so it answers for itself
// and its programs. The call is private (libquarantine): looked up, and
// skipped where it isn't there.
static void disclaim_responsibility(posix_spawnattr_t *attr) {
    typedef int (*disclaim_fn)(posix_spawnattr_t *, int);
    static disclaim_fn disclaim;
    static int looked_up;
    if (!looked_up) {
        disclaim = (disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
        looked_up = 1;
    }
    if (disclaim) disclaim(attr, 1);
}

pid_t libertty_spawn_detached(const char *path, char *const argv[], char *const envp[], const char *log_path) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&actions);
    disclaim_responsibility(&attr);
    // Its own session: it outlives the app and gets none of its signals.
    // Close everything else: the daemon must not hold the app's descriptors.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                        | POSIX_SPAWN_SETSIGMASK);
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log_path ? log_path : "/dev/null",
                                     O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    pid_t pid = -1;
    int err = posix_spawn(&pid, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        errno = err;
        return -1;
    }
    return pid;
}
#endif

int libertty_socketpair(int fds[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
        int nosigpipe = 1;
        setsockopt(fds[i], SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
#endif
    }
    return 0;
}

pid_t libertty_spawn_io(const char *path, char *const argv[], char *const envp[], int in_fd, int out_fd, int err_fd) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&actions);
    // Its own process group (^C in the shell that ran `libertty` isn't its), and
    // only the three descriptors given.
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setpgroup(&attr, 0);
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    int fds[3] = { in_fd, out_fd, err_fd };
    for (int i = 0; i < 3; i++) {
        if (fds[i] >= 0) posix_spawn_file_actions_adddup2(&actions, fds[i], i);
        else posix_spawn_file_actions_addopen(&actions, i, "/dev/null", i == 0 ? O_RDONLY : O_WRONLY, 0);
    }
    pid_t pid = -1;
    int err = posix_spawn(&pid, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        errno = err;
        return -1;
    }
    return pid;
}

static int write_all(int fd, const char *p, ssize_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, (size_t)n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= w;
    }
    return 0;
}

int libertty_bridge(int in_fd, int out_fd, int sock) {
    struct pollfd fds[2] = { { .fd = in_fd, .events = POLLIN }, { .fd = sock, .events = POLLIN } };
    static char buf[1 << 16];
    int input_open = 1;
    while (1) {
        int n = poll(fds, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (input_open && (fds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t r = read(in_fd, buf, sizeof(buf));
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) {
                // The client went away: let liberttyd see the end, then drain its side.
                input_open = 0;
                fds[0].fd = -1;
                shutdown(sock, SHUT_WR);
            } else if (write_all(sock, buf, r) != 0) {
                return 0;
            }
        }
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t r = read(sock, buf, sizeof(buf));
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0 || write_all(out_fd, buf, r) != 0) return 0;
        }
    }
}
