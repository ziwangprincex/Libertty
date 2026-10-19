// winshot PID OUT.png [LAYER]: capture the frontmost on-screen window of a
// process at that window layer (0, normal windows, by default; 3 for floating
// panels), for checking test instances without touching the user's windows.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4, let pid = Int32(args[1]) else {
    print("usage: winshot PID OUT.png [LAYER]")
    exit(2)
}
let layer = args.count == 4 ? Int(args[3]) ?? 0 : 0
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == layer }),
      let id = w[kCGWindowNumber as String] as? Int else {
    print("no window for \(pid)")
    exit(1)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-o", "-l\(id)", args[2]]
try p.run()
p.waitUntilExit()
print(args[2])
