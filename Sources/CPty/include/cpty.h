#ifndef LIBERTTY_CPTY_H
#define LIBERTTY_CPTY_H

#include <stdint.h>
#include <sys/types.h>

/// Spawn `path` with `argv`/`envp` on a new pseudo-terminal of the given size,
/// as a session leader with the pty as its controlling terminal, and no other
/// descriptor than the terminal as stdin, stdout and stderr.
/// Returns the child pid and stores the master fd (close-on-exec) in
/// `*master_out`, or returns -1 with errno set.
pid_t libertty_pty_spawn(const char *path,
                      char *const argv[],
                      char *const envp[],
                      const char *cwd,
                      uint16_t cols, uint16_t rows,
                      uint16_t width_px, uint16_t height_px,
                      int *master_out);

/// TIOCSWINSZ on the master; the kernel sends SIGWINCH to the foreground group.
int libertty_pty_resize(int master, uint16_t cols, uint16_t rows,
                     uint16_t width_px, uint16_t height_px);

/// Foreground process group of the pty (for "is a program running?" checks).
pid_t libertty_pty_foreground_pgid(int master);

/// Every descendant of `root` (not `root` itself), breadth first: children
/// before grandchildren. Returns how many were written to `out`.
int libertty_proc_descendants(pid_t root, pid_t *out, int cap);

/// The process's short name (as `ps -c`), or "" if it's gone.
void libertty_proc_name(pid_t pid, char *out, int cap);

/// The process's arguments after argv[0], space-joined ("/…/claude-code/cli.js
/// --resume"), or "" — argv[0] is the binary, which for an interpreter (node,
/// python) says nothing about the program. Returns what was written.
int libertty_proc_argv(pid_t pid, char *out, int cap);

/// The process's working directory, or "" if unavailable.
void libertty_proc_cwd(pid_t pid, char *out, int cap);

/// Foreground process group of the process's controlling terminal, or -1
/// (works without the pty descriptor, e.g. for a session liberttyd holds).
pid_t libertty_proc_tty_pgid(pid_t pid);

/// TCP ports the process is listening on. Returns how many were written.
int libertty_proc_listening_ports(pid_t pid, uint16_t *out, int cap);

/// One listening socket: its port and the address it's bound to.
struct libertty_listener {
    uint16_t port;
    /// "127.0.0.1", "0.0.0.0", "::1" — room for an IPv6 address and its NUL.
    char address[46];
};

/// The same with each socket's address (macOS; on Linux they are read
/// through libertty_proc_socket_inodes). Returns how many were written, or
/// -1 when the process's descriptors can't be read (another user's): what
/// it listens on then stays unknown, not empty.
int libertty_proc_listeners(pid_t pid, struct libertty_listener *out, int cap);

/// The inodes of the process's sockets (Linux; macOS answers -1), the
/// numbers /proc/net/tcp's rows carry: those rows say which ones listen and
/// where. Returns how many were written, or -1 when its descriptors can't
/// be read.
int libertty_proc_socket_inodes(pid_t pid, uint64_t *out, int cap);

/// One process, for the task manager.
struct libertty_proc {
    pid_t pid, ppid;
    uid_t uid;
    /// CPU time used so far, user + system, in nanoseconds (deltas give CPU %).
    uint64_t cpu_ns;
    /// Resident memory, bytes.
    uint64_t rss;
    int32_t threads;
    /// When it started, seconds since 1970.
    int64_t started;
    /// 'R' running, 'S' sleeping, 'T' stopped, 'Z' zombie, '?' unknown.
    char state;
    /// Whether its CPU time, memory and start were readable (another user's
    /// process shows only its name and parent).
    char known;
    char name[64];
};

/// The whole machine's CPU ticks so far (every core): busy (user, system,
/// nice) and idle. Deltas give how busy it is.
int libertty_host_cpu(uint64_t *busy, uint64_t *idle);

/// When `pid` started (seconds, microseconds since 1970); 0 when it's gone or not ours.
int libertty_proc_started(pid_t pid, int64_t *seconds, int64_t *microseconds);

/// Every process the kernel lets us see (others' too: their name and
/// numbers, not their memory or arguments). Returns how many were written.
int libertty_proc_snapshot(struct libertty_proc *out, int cap);

/// Raise the soft limit on open descriptors as far as the hard limit lets
/// it (and macOS's OPEN_MAX; at most 65536); never lower it.
void libertty_raise_fd_limit(void);

/// In a child, after fork and before exec: the soft limit back to what it
/// was before libertty_raise_fd_limit (a program run in a pane gets the
/// system's, as in any other terminal). Async-signal-safe.
void libertty_child_fd_limit(void);

/// In a child, after fork and before exec: close every open descriptor
/// from `lowest` up — those actually open, not every number to the limit
/// (65536 close calls took a tenth of a second on macOS). Async-signal-safe.
void libertty_close_from(int lowest);

/// Unix-domain stream sockets for liberttyd. Descriptors are close-on-exec and
/// never raise SIGPIPE. listen() replaces a stale socket file; connect() and
/// accept() refuse a peer running as another user. All return -1 with errno on failure.
int libertty_sock_listen(const char *path);
int libertty_sock_connect(const char *path);
int libertty_sock_accept(int listener);
/// The process at the other end of an accepted connection, or 0 if unknown.
pid_t libertty_sock_peer_pid(int fd);
/// The regular file `fd` is open on (liberttyd's log, its stderr), into
/// `out`; -1 and an empty string for anything else.
int libertty_fd_path(int fd, char *out, int cap);

/// Pass a descriptor over the socket (one byte of data rides along).
int libertty_sock_send_fd(int sock, int fd);
/// Receive one passed descriptor, or -1.
int libertty_sock_recv_fd(int sock);

/// Start `path` in its own session with stdin from /dev/null and output
/// appended to `log_path` (or /dev/null); no other descriptors are inherited.
/// `responsible` (macOS): it answers for itself, not for whoever started it,
/// when macOS asks the user about its programs' privacy access.
pid_t libertty_spawn_detached(const char *path, char *const argv[], char *const envp[], const char *log_path,
                              int responsible);
/// The same with stdin from `in_fd` (liberttyd's guardian: the socket it
/// talks to liberttyd over), and `pass_fd` (unless -1) as its descriptor 3
/// (the guardian: liberttyd's lock, held).
pid_t libertty_spawn_detached_stdin(const char *path, char *const argv[], char *const envp[], const char *log_path,
                                    int responsible, int in_fd, int pass_fd);

/// A connected pair of Unix stream sockets (close-on-exec, no SIGPIPE).
int libertty_socketpair(int fds[2]);

/// Start `path` in its own process group with stdin/stdout/stderr from the
/// given descriptors (-1: /dev/null) and nothing else inherited.
pid_t libertty_spawn_io(const char *path, char *const argv[], char *const envp[], int in_fd, int out_fd, int err_fd);

/// Copy `in_fd` to `sock` and `sock` to `out_fd` until `sock` closes
/// (liberttyd --bridge: a connection carried over ssh's stdin and stdout).
int libertty_bridge(int in_fd, int out_fd, int sock);

#endif
