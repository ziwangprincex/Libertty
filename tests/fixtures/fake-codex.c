// A stand-in for Codex in tests/fixtures/agent-screen.txt: its screen at
// work (a turn's timer), then at rest, as Codex draws them. Built by
// tests/run.sh as "codex", the name Libertty knows the agent by.
#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("\033[H\033[2J• Ran ls\n  └ a b\n\n• Working (5s • esc to interrupt)\n\n› hi\n");
    fflush(stdout);
    sleep(4);
    printf("\033[H\033[2J• Done, two files.\n\n› hi\n");
    fflush(stdout);
    sleep(60);
    return 0;
}
