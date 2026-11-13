import Testing
@testable import LiberttyApp

/// Releases in order, betas before the release they lead to (the beta channel).
struct VersionTests {
    @Test func order() {
        let ordered = ["0.6.7", "0.7.0-beta.1", "0.7.0-beta.2", "0.7.0-beta.10", "0.7.0-rc.1", "0.7.0", "0.7.1", "1.0.0"]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(Version(a) < Version(b), "\(a) < \(b)")
            #expect(!(Version(b) < Version(a)), "not \(b) < \(a)")
        }
        #expect(Version("v0.7.0") == Version("0.7.0"))
        #expect(Version("0.7") == Version("0.7.0"))
        #expect(Version("0.7.0+build.5") == Version("0.7.0"))
        #expect(Version("0.7.0-beta.1").isPrerelease && !Version("0.7.0").isPrerelease)
        // Numbers before words, and a longer prerelease after its prefix.
        #expect(Version("1.0.0-1") < Version("1.0.0-alpha"))
        #expect(Version("1.0.0-alpha") < Version("1.0.0-alpha.1"))
    }
}
