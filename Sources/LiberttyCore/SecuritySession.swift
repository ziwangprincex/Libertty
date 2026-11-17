#if canImport(Security)
import Security
#endif

/// Which login a process belongs to, as macOS counts logins. A Mac has one
/// session for the user sitting at it (it can draw on the screen, and the
/// login keychain is unlocked in it) and a separate one for every ssh login
/// into the machine.
///
/// It matters to liberttyd because of what it is: one per user, on one
/// socket. A Mac that is also reached as a Remote Host runs
/// `liberttyd --ensure` from the ssh login, and that liberttyd would stay in
/// sshd's session — then every local pane it starts later is outside the
/// user's own login, without the login keychain (ssh keys, git credentials)
/// and possibly without what the Mac's privacy settings grant the app. So
/// liberttyd says which session it is in, and the app replaces one that
/// answers from the wrong side (see DaemonClient.start).
public struct SecuritySession: Sendable, Equatable, CustomStringConvertible {
    public var id: UInt32
    /// It can reach the screen: the session of whoever is logged in at the
    /// Mac, which is where Libertty itself runs.
    public var hasGraphicAccess: Bool
    /// macOS made it for a login from elsewhere (sshd's).
    public var isRemote: Bool

    /// The session this process is in; nil where there is no such notion
    /// (Linux), or when the system wouldn't say.
    public static var current: SecuritySession? {
        #if canImport(Security)
        var id: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, &id, &attributes) == errSecSuccess else { return nil }
        return SecuritySession(id: UInt32(bitPattern: Int32(truncatingIfNeeded: id)),
                               hasGraphicAccess: attributes.contains(.sessionHasGraphicAccess),
                               isRemote: attributes.contains(.sessionIsRemote))
        #else
        return nil
        #endif
    }

    /// What liberttyd puts in its `welcome` and `info`, and the app reads back.
    public var asJSON: [String: Any] {
        ["id": Int(id), "graphic": hasGraphicAccess, "remote": isRemote]
    }

    public init(id: UInt32, hasGraphicAccess: Bool, isRemote: Bool) {
        self.id = id
        self.hasGraphicAccess = hasGraphicAccess
        self.isRemote = isRemote
    }

    public init?(json: Any?) {
        guard let json = json as? [String: Any], let graphic = json["graphic"] as? Bool else { return nil }
        self.init(id: UInt32(truncatingIfNeeded: json["id"] as? Int ?? 0), hasGraphicAccess: graphic,
                  isRemote: json["remote"] as? Bool ?? false)
    }

    /// Named so it reads in a sentence ("answers from …") and as a row of
    /// `+daemon status`.
    public var description: String {
        if hasGraphicAccess { return "the login at this Mac" }
        return isRemote ? "an ssh login into this Mac" : "a login without access to this Mac's screen"
    }
}
