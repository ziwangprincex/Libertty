#if os(macOS)
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
#endif

/// What macOS lets this process — and the programs it starts — get at (Rex's
/// System Permissions). liberttyd answers for itself and its sessions when
/// macOS asks (`libertty_spawn_detached`), so the programs in your panes have
/// what liberttyd was granted: it reports its own, for Settings to show.
/// Asking never prompts. On Linux there's nothing to report.
public enum PrivacyAccess {
    public enum Status: String { case granted, denied, notAsked = "not-asked", unknown }

    /// What's reported, in the order Settings lists them.
    public static let kinds = ["full-disk", "screen", "camera", "microphone", "local-network"]

    /// Each kind's status by its name (`Status.rawValue`).
    public static func report() -> [String: String] {
        #if os(macOS)
        [
            "full-disk": fullDisk().rawValue,
            // Granted or not; it can't tell "not asked" from "said no".
            "screen": (CGPreflightScreenCaptureAccess() ? Status.granted : .denied).rawValue,
            "camera": capture(.video).rawValue,
            "microphone": capture(.audio).rawValue,
            // macOS has no way to ask.
            "local-network": Status.unknown.rawValue,
        ]
        #else
        [:]
        #endif
    }

    #if os(macOS)
    /// Full Disk Access: whether a privacy database (yours, else the
    /// system's) opens, which only it allows.
    static func fullDisk() -> Status {
        for path in [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                     "/Library/Application Support/com.apple.TCC/TCC.db"] {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .denied }
        }
        return .unknown
    }

    static func capture(_ media: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }
    #endif
}
