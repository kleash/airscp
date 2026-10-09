import Foundation
import Testing
@testable import AirSCPCore

// MARK: Import from WinSCP (task 70)

/// A WinSCP.ini as WinSCP's Tools ▸ Export/Backup Configuration writes it: escaped names and values, folders, a
/// tunnel, an HTTP proxy, the default settings, a workspace, and sites AirSCP can't use.
private let ini = """
    [Configuration\\Interface]
    Theme=1

    [Sessions\\Default%20Settings]
    HostName=never.example.com

    [Sessions\\Work/Web/web%2001]
    HostName=web01.example.com
    UserName=deploy
    PortNumber=2222
    RemoteDirectory=/var/www
    PublicKeyFile=C:%5CUsers%5Cme%5CKeys%5Cdeploy.ppk
    Password=A35C4D5B2F0F7A3C3B2D3E3F
    FSProtocol=2

    [Sessions\\Work/Web/db]
    HostName=10.0.0.5
    UserName=postgres
    Tunnel=1
    TunnelHostName=bastion.example.com
    TunnelUserName=jump
    TunnelPortNumber=2022
    ProxyMethod=3
    ProxyHost=proxy.corp
    ProxyPort=3128
    ProxyUsername=me

    [Sessions\\Work/Web/cache]
    HostName=10.0.0.6
    Tunnel=1
    TunnelHostName=bastion.example.com
    TunnelUserName=jump
    TunnelPortNumber=2022

    [Sessions\\plain]
    HostName=plain.example.com
    FSProtocol=0

    [Sessions\\ftp%20site]
    HostName=ftp.example.com
    FSProtocol=5

    [Sessions\\socks]
    HostName=behind.example.com
    ProxyMethod=2
    ProxyHost=socks.corp

    [Sessions\\My%20Workspace/0000]
    HostName=web01.example.com
    IsWorkspace=1

    """

@Test func winSCPSitesAreReadWithoutTheirPasswords() {
    let sites = WinSCP.sites(in: ini.replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(sites.map(\.name) == ["web 01", "db", "cache", "plain", "ftp site", "socks"])
    let web = sites[0]
    #expect(web.folder == "Work/Web" && web.hostname == "web01.example.com" && web.port == 2222 && web.username == "deploy")
    #expect(web.remoteDirectory == "/var/www" && web.keyName == "deploy.ppk" && web.leftOut == nil)
    #expect(sites[1].tunnel == WinSCP.Hop(host: "bastion.example.com", port: 2022, username: "jump"))
    #expect(sites[1].proxy == WinSCP.Hop(host: "proxy.corp", port: 3128, username: "me"))
    #expect(sites[3].leftOut == nil && sites[3].port == 22)
    #expect(sites[4].leftOut?.contains("FTP") == true)
    #expect(sites[5].leftOut?.contains("SOCKS") == true)
    #expect(WinSCP.sites(in: "").isEmpty && WinSCP.sites(in: "[Sessions\\x]\nHostName=-oProxyCommand=x\n")[0].leftOut != nil)
}

@Test func winSCPSitesBecomeHostsGroupsJumpHostsAndProxies() throws {
    let existing = HostGroup(name: "Work/Web")
    let data = WinSCP.data(WinSCP.sites(in: ini), existing: AirSCPData(groups: [existing]), key: { $0 == "deploy.ppk" ? "/keys/deploy" : nil })
    // The folder's group is the one AirSCP has; one jump host for both tunnels, one proxy, on the jump host.
    #expect(data.groups.isEmpty)
    #expect(data.hosts.map(\.label) == ["web 01", "bastion.example.com", "db", "cache", "plain"])
    let web = data.hosts[0], jump = data.hosts[1], db = data.hosts[2], cache = data.hosts[3]
    #expect(web.groupID == existing.id && web.port == 2222 && web.auth == .keyFile && web.keyFile == "/keys/deploy")
    #expect(web.defaultRemoteDir == "/var/www")
    #expect(jump.hostname == "bastion.example.com" && jump.port == 2022 && jump.username == "jump" && jump.auth == .agent)
    #expect(db.jumpHostID == jump.id && cache.jumpHostID == jump.id && db.proxyID == nil)
    let proxy = try #require(data.proxies.first)
    #expect(data.proxies.count == 1 && jump.proxyID == proxy.id && proxy.host == "proxy.corp" && proxy.port == 3128)
    #expect(data.hosts[4].port == nil && data.hosts[4].groupID == nil)
    // Without the group in AirSCP, the folder makes one.
    #expect(WinSCP.data(WinSCP.sites(in: ini)).groups.map(\.name) == ["Work/Web"])
    // Imported again: nothing new; with the jump host and proxy known, a new site through them reuses both.
    var have = AirSCPData(hosts: data.hosts, groups: [existing])
    have.proxies = data.proxies
    #expect(WinSCP.data(WinSCP.sites(in: ini), existing: have).hosts.isEmpty)
    have.hosts.removeAll { $0.label == "cache" }
    let again = WinSCP.data(WinSCP.sites(in: ini), existing: have)
    #expect(again.hosts.map(\.label) == ["cache"] && again.hosts[0].jumpHostID == jump.id && again.proxies.isEmpty)
}

@Test func winSCPKeysBesideTheFileBecomeOpenSSHKeys() async throws {
    let beside = try scratch(), folder = try scratch()
    // PuTTY's own test key (PuTTYKeyTests).
    let key = try PuTTYKey.read("""
        PuTTY-User-Key-File-3: ssh-ed25519
        Encryption: none
        Comment: ed25519-key-20200105
        Public-Lines: 2
        AAAAC3NzaC1lZDI1NTE5AAAAIHJCszOHaI9X/yGLtjn22f0hO6VPMQDVtctkym6F
        JH1W
        Private-Lines: 1
        AAAAIGvvIpl8jyqn8Xufkw6v3FnEGtXF3KWw55AP3/AGEBpY
        Private-MAC: 816c84093fc4877e8411b8e5139c5ce35d8387a2630ff087214911d67417a54d

        """, passphrase: "")
    try PuTTYKey.write(key, passphrase: "").write(toFile: beside + "/deploy.ppk", atomically: true, encoding: .utf8)
    try PuTTYKey.write(key, passphrase: "secret", passes: 1).write(toFile: beside + "/locked.ppk", atomically: true, encoding: .utf8)
    var sites = [WinSCP.Site(name: "a", hostname: "a", keyName: "deploy.ppk"), WinSCP.Site(name: "b", hostname: "b", keyName: "locked.ppk"),
                 WinSCP.Site(name: "c", hostname: "c", keyName: "missing.ppk")]
    var (keys, notes) = await WinSCP.importKeys(of: sites, beside: beside, into: folder)
    #expect(keys == ["deploy.ppk": folder + "/deploy"])
    #expect(read(folder + "/deploy.pub")?.hasPrefix(PuTTYKey.publicLine(key).split(separator: " ").prefix(2).joined(separator: " ")) == true)
    var info = stat()
    #expect(stat(folder + "/deploy", &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(notes.count == 2 && notes[0].contains("locked.ppk has a passphrase") && notes[1].contains("missing.ppk isn't beside"))
    // Again: the same key is used again; another key of that name is never replaced.
    (keys, _) = await WinSCP.importKeys(of: [sites[0]], beside: beside, into: folder)
    #expect(keys == ["deploy.ppk": folder + "/deploy"])
    try "ssh-ed25519 AAAAother other\n".write(toFile: folder + "/deploy.pub", atomically: true, encoding: .utf8)
    sites[0].name = "again"
    (keys, notes) = await WinSCP.importKeys(of: [sites[0]], beside: beside, into: folder)
    #expect(keys.isEmpty && notes.first?.contains("another key is named deploy") == true)
}
