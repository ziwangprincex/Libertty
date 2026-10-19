// Ed25519 keys and signatures for Libertty's update feed (see Updater.swift).
//   swift scripts/sign-update.swift --generate KEYFILE   new key; prints the public key
//   swift scripts/sign-update.swift --public KEYFILE     prints the public key
//   swift scripts/sign-update.swift KEYFILE FILE         prints FILE's signature (base64)
// KEYFILE holds the private key (base64). Keep it out of the repository and
// back it up: a lost key means installed copies can't verify new updates.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("sign-update: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func load(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("can't read a key from \(path)") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--generate":
    guard args.count == 2 else { fail("usage: --generate KEYFILE") }
    guard !FileManager.default.fileExists(atPath: args[1]) else { fail("\(args[1]) exists; not overwriting a key") }
    let key = Curve25519.Signing.PrivateKey()
    let dir = (args[1] as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard FileManager.default.createFile(atPath: args[1], contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("can't write \(args[1])") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "--public":
    guard args.count == 2 else { fail("usage: --public KEYFILE") }
    print(load(args[1]).publicKey.rawRepresentation.base64EncodedString())
default:
    guard args.count == 2 else { fail("usage: KEYFILE FILE") }
    guard let data = FileManager.default.contents(atPath: args[1]) else { fail("can't read \(args[1])") }
    guard let signature = try? load(args[0]).signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())
}
