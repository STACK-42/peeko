// Signs an update archive for Sparkle: an Ed25519 signature over the file's bytes, base64.
// Usage: SPARKLE_PRIVATE_KEY=<base64 32-byte seed> swift scripts/sign-update.swift <file>
// Prints the signature. The public half is SUPublicEDKey in Resources/Info.plist.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file>\n".utf8))
    exit(2)
}
guard let encoded = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"],
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("SPARKLE_PRIVATE_KEY is missing or not a base64 Ed25519 seed\n".utf8))
    exit(1)
}

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let signature = try key.signature(for: archive)
guard key.publicKey.isValidSignature(signature, for: archive) else { exit(1) }
print(signature.base64EncodedString())
