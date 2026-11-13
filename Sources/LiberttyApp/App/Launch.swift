import AppKit

/// What the `Libertty` executable runs: the command line (`libertty +ACTION`
/// never starts the app), the probes in a debug build, else the app.
public enum Launch {
    public static func run() -> Never {
        CLI.runIfRequested()
        #if LIBERTTY_PROBES
        StartupBench.mark("main")
        StartupBench.startSampling()
        Snapshot.runIfRequested()  // the probes and benches: debug builds only
        ProbeLauncher.runIfRequested()
        #else
        // A probe asked of a build without them must not go on into the app: it
        // would open a real window and reach (take over) the user's liberttyd.
        if CommandLine.arguments.dropFirst().contains(where: {
            $0 == "--snapshot" || $0.hasSuffix("-probe") || $0.hasSuffix("-bench") || $0.hasSuffix("-trace")
        }) {
            FileHandle.standardError.write(Data("libertty: probes and benches are in debug builds only (swift build)\n".utf8))
            exit(2)
        }
        #endif
        FontWarmup.start()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        #if LIBERTTY_PROBES
        // Off screen, out of the Dock and never in front.
        app.setActivationPolicy(StartupBench.offscreen ? .accessory : .regular)
        #else
        app.setActivationPolicy(.regular)
        #endif
        app.run()
        exit(0)
    }
}
