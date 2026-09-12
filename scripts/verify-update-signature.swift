import Foundation
import CryptoKit

// Verify the archive against the public key embedded in the app being shipped,
// not merely against whatever private key the packager supplied.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else { exit(2) }
do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: archive) else { exit(1) }
} catch { exit(1) }
