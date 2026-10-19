// The plugin probe's plugin: a command that types into the terminal, a
// handler for finished commands, a timer, and storage.
libertty.command("Say Hello", () => {
  libertty.send("echo plugin-said-" + "hi\n");
  libertty.storage.set("count", (libertty.storage.get("count") || 0) + 1);
});
libertty.on("commandFinished", (e) => console.log("finished: " + e.command));
setTimeout(() => console.log("timer fired"), 50);
