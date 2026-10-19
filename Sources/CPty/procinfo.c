// Process facts for the inspector: descendants of a shell, their names and
// working directories, and the TCP ports they listen on. libproc only; no
// privileges needed for the user's own processes.
#include "cpty.h"

#ifdef __APPLE__
#include <arpa/inet.h>
#include <libproc.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <mach/mach_time.h>
#include <mach/mach_host.h>
#include <mach/mach_init.h>
#include <stdlib.h>

int libertty_proc_descendants(pid_t root, pid_t *out, int cap) {
    int count = 0, next = 0;
    pid_t queue_root = root;
    pid_t children[512];
    for (;;) {
        // proc_listchildpids answers how many pids it wrote, not how many
        // bytes (unlike proc_listpids): read as bytes, fewer than four
        // children would come out as none.
        int n = proc_listchildpids(queue_root, children, sizeof children);
        if (n < 0) n = 0;
        if (n > (int)(sizeof children / sizeof children[0])) n = sizeof children / sizeof children[0];
        for (int i = 0; i < n && count < cap; i++) {
            if (children[i] > 0) out[count++] = children[i];
        }
        if (next >= count) break;
        queue_root = out[next++];
    }
    return count;
}

void libertty_proc_name(pid_t pid, char *out, int cap) {
    if (cap <= 0) return;
    out[0] = 0;
    if (proc_name(pid, out, (uint32_t)cap) <= 0) out[0] = 0;
}

int libertty_proc_argv(pid_t pid, char *out, int cap) {
    if (cap <= 0) return 0;
    out[0] = 0;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) return 0;
    // The block holds the environment after the arguments and there is no
    // way to ask for less, so a process with a huge environment would have
    // it copied here every poll. Past a megabyte, go without.
    if (size > (1u << 20)) return 0;
    char *buf = malloc(size);
    if (!buf) return 0;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) { free(buf); return 0; }
    int argc = 0;
    memcpy(&argc, buf, sizeof argc);
    char *p = buf + sizeof argc, *end = buf + size;
    // The layout is: argc, the executable path, NUL padding, then argv[0…].
    // Padding and an empty argv[0] are indistinguishable, so a program
    // whose argv[0] is "" loses one argument here; nothing does that.
    while (p < end && *p) p++;
    while (p < end && !*p) p++;
    int written = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t len = strnlen(p, (size_t)(end - p));
        if (i > 0) {  // skip argv[0]: the interpreter, not the program
            if (written > 0 && written < cap - 1) out[written++] = ' ';
            for (size_t k = 0; k < len && written < cap - 1; k++) out[written++] = p[k];
        }
        p += len + 1;
    }
    out[written] = 0;
    free(buf);
    return written;
}

void libertty_proc_cwd(pid_t pid, char *out, int cap) {
    if (cap <= 0) return;
    out[0] = 0;
    struct proc_vnodepathinfo info;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info) == (int)sizeof info) {
        strlcpy(out, info.pvi_cdir.vip_path, (size_t)cap);
    }
}

int libertty_proc_listening_ports(pid_t pid, uint16_t *out, int cap) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) return 0;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int n = bytes > 0 ? bytes / (int)sizeof(struct proc_fdinfo) : 0, count = 0;
    for (int i = 0; i < n && count < cap; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo si;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != (int)sizeof si) continue;
        if (si.psi.soi_kind != SOCKINFO_TCP || si.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
        uint16_t port = ntohs((uint16_t)si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
        int dup = 0;
        for (int j = 0; j < count; j++) if (out[j] == port) dup = 1;
        if (!dup) out[count++] = port;
    }
    free(fds);
    return count;
}

int libertty_proc_snapshot(struct libertty_proc *out, int cap) {
    // A count of pids (not bytes, despite the man page), plus room for new ones.
    int listed = proc_listallpids(NULL, 0);
    if (listed <= 0) return 0;
    int room = listed + 64;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)room);
    if (!pids) return 0;
    int n = proc_listallpids(pids, (int)sizeof(pid_t) * room);
    // Mach time to nanoseconds (Apple silicon counts in 41.67 ns ticks).
    static mach_timebase_info_data_t base;
    if (base.denom == 0) mach_timebase_info(&base);
    int count = 0;
    for (int i = 0; i < n && count < cap; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct libertty_proc *p = &out[count];
        memset(p, 0, sizeof *p);
        struct proc_taskallinfo all;
        if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, sizeof all) == (int)sizeof all) {
            p->pid = pid;
            p->known = 1;
            p->ppid = (pid_t)all.pbsd.pbi_ppid;
            p->uid = all.pbsd.pbi_uid;
            p->started = (int64_t)all.pbsd.pbi_start_tvsec;
            uint64_t ticks = all.ptinfo.pti_total_user + all.ptinfo.pti_total_system;
            p->cpu_ns = ticks * base.numer / base.denom;
            p->rss = all.ptinfo.pti_resident_size;
            p->threads = all.ptinfo.pti_threadnum;
            switch (all.pbsd.pbi_status) {
            case SRUN: p->state = 'R'; break;
            case SSLEEP: p->state = 'S'; break;
            case SSTOP: p->state = 'T'; break;
            case SZOMB: p->state = 'Z'; break;
            default: p->state = '?';
            }
            strlcpy(p->name, all.pbsd.pbi_name[0] ? all.pbsd.pbi_name : all.pbsd.pbi_comm, sizeof p->name);
        } else {
            // Not ours to look into: its name and parent still show.
            struct proc_bsdshortinfo info;
            if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) continue;
            p->pid = pid;
            p->ppid = (pid_t)info.pbsi_ppid;
            p->uid = info.pbsi_uid;
            p->state = '?';
            strlcpy(p->name, info.pbsi_comm, sizeof p->name);
        }
        // The long name when the short one was cut (proc_name has it).
        char longer[2 * MAXCOMLEN + 1];
        if (proc_name(pid, longer, sizeof longer) > 0 && strlen(longer) > strlen(p->name)) strlcpy(p->name, longer, sizeof p->name);
        count++;
    }
    free(pids);
    return count;
}

int libertty_host_cpu(uint64_t *busy, uint64_t *idle) {
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS) return 0;
    *busy = (uint64_t)load.cpu_ticks[CPU_STATE_USER] + load.cpu_ticks[CPU_STATE_SYSTEM] + load.cpu_ticks[CPU_STATE_NICE];
    *idle = load.cpu_ticks[CPU_STATE_IDLE];
    return 1;
}

int libertty_proc_started(pid_t pid, int64_t *seconds, int64_t *microseconds) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return 0;
    *seconds = (int64_t)info.pbi_start_tvsec;
    *microseconds = (int64_t)info.pbi_start_tvusec;
    return 1;
}

pid_t libertty_proc_tty_pgid(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return -1;
    return (pid_t)info.e_tpgid;
}

#else
// Linux (liberttyd on a remote host): /proc. Only what liberttyd needs is real;
// the inspector's facts belong to the app, which runs on a Mac.
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int libertty_proc_descendants(pid_t root, pid_t *out, int cap) {
    (void)root; (void)out; (void)cap;
    return 0;
}

void libertty_proc_name(pid_t pid, char *out, int cap) {
    if (cap <= 0) return;
    out[0] = 0;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/comm", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fgets(out, cap, f)) out[strcspn(out, "\n")] = 0;
    fclose(f);
}

int libertty_proc_argv(pid_t pid, char *out, int cap) {
    if (cap <= 0) return 0;
    out[0] = 0;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cmdline", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(out, 1, (size_t)cap - 1, f);
    fclose(f);
    out[n] = 0;
    // NUL-separated; drop argv[0] and join what's left with spaces.
    size_t start = 0;
    while (start < n && out[start]) start++;
    while (start < n && !out[start]) start++;
    int written = 0;
    for (size_t i = start; i < n; i++) {
        out[written++] = out[i] ? out[i] : ' ';
    }
    while (written > 0 && out[written - 1] == ' ') written--;
    out[written] = 0;
    return written;
}

void libertty_proc_cwd(pid_t pid, char *out, int cap) {
    if (cap <= 0) return;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cwd", (int)pid);
    ssize_t n = readlink(path, out, (size_t)cap - 1);
    out[n > 0 ? n : 0] = 0;
}

int libertty_proc_listening_ports(pid_t pid, uint16_t *out, int cap) {
    (void)pid; (void)out; (void)cap;
    return 0;
}

int libertty_proc_snapshot(struct libertty_proc *out, int cap) {
    (void)out; (void)cap;
    return 0;
}

pid_t libertty_proc_tty_pgid(pid_t pid) {
    // /proc/PID/stat: pid (comm) state ppid pgrp session tty_nr tpgid ...
    char path[64], buf[1024];
    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = strrchr(buf, ')');  // comm may hold spaces and parentheses
    if (!p) return -1;
    char state;
    int ppid, pgrp, session, tty, tpgid;
    if (sscanf(p + 1, " %c %d %d %d %d %d", &state, &ppid, &pgrp, &session, &tty, &tpgid) != 6) return -1;
    return (pid_t)tpgid;
}
int libertty_host_cpu(uint64_t *busy, uint64_t *idle) { (void)busy; (void)idle; return 0; }
int libertty_proc_started(pid_t pid, int64_t *seconds, int64_t *microseconds) {
    (void)pid; (void)seconds; (void)microseconds;
    return 0;
}
#endif
