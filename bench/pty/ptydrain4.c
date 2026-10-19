// Like ptydrain3, but drain the way Tern's pty reader does: non-blocking reads,
// spin on EAGAIN up to SPIN times, then poll(); optional QoS user-interactive.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
int main(int argc, char **argv) {
    int spin = atoi(argv[1]); int qos = atoi(argv[2]);
    if (qos) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    int master; struct winsize ws = {40, 120, 0, 0};
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid == 0) { execvp(argv[3], argv + 3); _exit(127); }
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    char *buf = malloc(1 << 16); long total = 0, reads = 0, polls = 0; int misses = 0;
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
    for (;;) {
        ssize_t n = read(master, buf, 1 << 16);
        if (n > 0) { total += n; reads++; misses = 0; continue; }
        if (n == 0 || (errno != EAGAIN && errno != EINTR)) break;
        if (++misses <= spin) continue;
        struct pollfd p = {master, POLLIN, 0}; polls++;
        if (poll(&p, 1, -1) < 0) break;
        misses = 0;
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    double s = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    printf("spin=%-4d qos=%d  %.0f MB/s  avg read %ld B  polls %ld\n", spin, qos, total / 1e6 / s, total / (reads ? reads : 1), polls);
    waitpid(pid, NULL, 0); return 0;
}
