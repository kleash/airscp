import Foundation
import Testing
@testable import AirSCPCore

// What the App Store version adds that the default build has too: its `#if APPSTORE` parts only switch these on.

/// A folder the person chose in an Open panel opens again at the next launch: kept as a security-scoped bookmark, one
/// per folder, and dropped once the folder is gone.
@Test func chosenFoldersAreKeptAndOpenedAgainAtLaunch() throws {
    let defaults = try #require(MemoryDefaults(suiteName: nil))
    let keys = try scratch(), mac = try scratch()
    #expect(FolderAccess.remember(URL(fileURLWithPath: keys, isDirectory: true), in: defaults))
    #expect(FolderAccess.remember(URL(fileURLWithPath: keys, isDirectory: true), in: defaults))  // again: still one
    #expect(FolderAccess.remember(URL(fileURLWithPath: mac, isDirectory: true), in: defaults))
    #expect((defaults.values[FolderAccess.key] as? [Data])?.count == 2)

    let opened = FolderAccess.restore(from: defaults)
    #expect(FolderAccess.covers(keys + "/id_ed25519", in: opened) && FolderAccess.covers(mac, in: opened))
    try FileManager.default.removeItem(atPath: mac)
    FolderAccess.restore(from: defaults)
    #expect((defaults.values[FolderAccess.key] as? [Data])?.count == 1)
}

/// A path is in a folder when it is the folder or below it, however its links are spelled (/tmp is /private/tmp).
@Test func aFolderCoversWhatIsBelowItOnly() throws {
    #expect(FolderAccess.covers("/a/b", in: ["/a/b"]) && FolderAccess.covers("/a/b/c/d", in: ["/a/b"]))
    #expect(!FolderAccess.covers("/a/bc", in: ["/a/b"]) && !FolderAccess.covers("/a", in: ["/a/b"]))
    #expect(FolderAccess.covers("/anything", in: ["/"]) && !FolderAccess.covers("/a/b", in: []))
    let folder = try scratch()
    let spelled = folder.hasPrefix("/private/") ? String(folder.dropFirst("/private".count)) : "/private" + folder
    #expect(FolderAccess.covers(spelled + "/x", in: [folder]))
}

/// The App Store version's SSH folder when it isn't ~/.ssh: ssh gets its config (or none, never the real one), its
/// default keys that exist, in ssh's order, for a host without a key of its own, and its known_hosts.
@Test func sshCommandsNameTheChosenSSHFolder() throws {
    let folder = try scratch() + "/my keys"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    #expect(OpenSSH.folderConfig(folder) == ["-F", "none", "-o", "IdentityFile=none"])
    for name in ["config", "id_ed25519", "id_rsa", "id_ed25519.pub"] {
        try "x".write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
    }
    #expect(OpenSSH.folderConfig(folder) == ["-F", folder + "/config", "-o", "IdentityFile=none"])

    var host = SSHHost()
    host.hostname = "example.com"
    #expect(OpenSSH.folderDefaults(folder, for: host) == [
        "-o", "IdentityFile=\"\(folder)/id_rsa\"", "-o", "IdentityFile=\"\(folder)/id_ed25519\"",
        "-o", "UserKnownHostsFile=\"\(folder)/known_hosts\"",
    ])
    host.auth = .keyFile
    host.keyFile = "/elsewhere/deploy_key"
    #expect(OpenSSH.folderDefaults(folder, for: host) == ["-o", "UserKnownHostsFile=\"\(folder)/known_hosts\""])
    // ssh reads % in these as its tokens.
    #expect(OpenSSH.folderDefaults("/k%h", for: host) == ["-o", "UserKnownHostsFile=/k%%h/known_hosts"])
}
