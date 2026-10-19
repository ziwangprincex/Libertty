// Run argv[1..] on a pty, drain the master with 64 KiB reads, report MB/s.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <util.h>
#include <sys/wait.h>
#include <time.h>
int main(int argc, char **argv) {
    int master; struct winsize ws = {40, 120, 0, 0};
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid == 0) { execvp(argv[1], argv + 1); _exit(127); }
    char *buf = malloc(1 << 16); long total = 0, reads = 0; ssize_t n;
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
    while ((n = read(master, buf, 1 << 16)) > 0) { total += n; reads++; }
    clock_gettime(CLOCK_MONOTONIC, &b);
    double s = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
    printf("%.0f MB/s  avg read %ld bytes  (%ld MB)\n", total / 1e6 / s, total / (reads ? reads : 1), total / 1000000);
    waitpid(pid, NULL, 0); return 0;
}
