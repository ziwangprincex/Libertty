// A stand-in coding agent for tests/fixtures/prompt-queue.txt and
// composer.txt, built by tests/run.sh as "claude" (the name Libertty knows
// the agent by): it says it's at rest (OSC 7501, as Claude Code's hooks
// do), takes a line, works on it a moment, then says it's done; the line
// "ask" first waits for you (blocked) a while, as a permission question would.
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void state(const char *s) {
    printf("\033]7501;state=%s:app=claude\a", s);
    fflush(stdout);
}

int main(void) {
    char line[4096];
    state("idle");
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        state("working");
        if (strcmp(line, "ask") == 0) {
            usleep(500000);
            state("blocked");
            sleep(3);
            state("working");
        }
        usleep(1200000);
        printf("GOT[%s]\n", line);
        state("done");
    }
    return 0;
}
