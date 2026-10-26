#if LIBERTTY_PROBES
import AppKit
import ImageIO
import CGhosttyVt
import LiberttyCore
import Foundation

extension ProbeLauncher {
    /// `Libertty --responsible-probe PID`: the process macOS holds responsible
    /// for PID — the one its camera, microphone, … requests are asked in the
    /// name of. For a session's program that should be liberttyd itself.
    static func responsibleProbe(_ pid: pid_t) -> Never {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            print("responsible: unknown (no responsibility_get_pid_responsible_for_pid)")
            exit(1)
        }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)(pid)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard responsible > 0, proc_pidpath(responsible, &buffer, UInt32(buffer.count)) > 0 else {
            print("responsible: pid \(responsible), not running")
            exit(1)
        }
        print("responsible: \(String(cString: buffer))")
        exit(0)
    }
}
#endif
