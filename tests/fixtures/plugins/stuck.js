// The plugin probe's stuck plugin: a command that never returns (only its own thread waits).
libertty.command("Spin", () => { for (;;) {} });
