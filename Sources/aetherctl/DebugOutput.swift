import Foundation

/// Audit OPS-3: debug artefacts go into one private directory per run (`mkdtemp`, mode 0700) under
/// the user's temporary directory. A fixed name in the shared `/tmp` could be pre-created as a
/// symlink by another local user, and the write would follow it.
let debugOutputDirectory: String = {
    let template = FileManager.default.temporaryDirectory.appendingPathComponent("aetherctl-XXXXXX").path
    var buffer = Array(template.utf8CString)
    if let made = mkdtemp(&buffer) {
        return String(cString: made)
    }
    let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("aetherctl-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: fallback, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    return fallback
}()

func debugOutputPath(_ name: String) -> String {
    (debugOutputDirectory as NSString).appendingPathComponent(name)
}
