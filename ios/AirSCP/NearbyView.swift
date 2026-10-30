import AirSCPCore
import dnssd
import Network
import SwiftUI

/// Servers on this network, as a sheet: those that announce themselves (Bonjour) and, when asked, the addresses
/// around this device's that answer on port 22. Tapping one gives it to `onChoose` as a server to add.
struct NearbyView: View {
    let onChoose: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nearby = Nearby()
    /// The announced server being looked up after a tap, and the one that didn't answer.
    @State private var resolving: String?
    @State private var unreachable: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if nearby.denied {
                        Label("AirSCP needs Local Network access to find servers. Turn it on in Settings ▸ Privacy & Security ▸ Local Network.",
                              systemImage: "exclamationmark.triangle")
                        Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                            .help("Open AirSCP's settings to turn on Local Network access")
                    } else if nearby.names.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label { Text("Looking for servers…") } icon: { ProgressView() }
                            Text("Macs with Remote Login and many NAS boxes show here. For others, scan this network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(nearby.names, id: \.self) { name in
                        Button { choose(name) } label: {
                            HStack {
                                // Colors: in a button, .primary and .secondary are shades of the tint.
                                VStack(alignment: .leading) {
                                    Text(name).foregroundStyle(Color.primary)
                                    Text(nearby.offers(name)).font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                if resolving == name { ProgressView() }
                            }
                        }
                        .help("Add this server with its address filled in")
                    }
                } header: {
                    Text("On this network")
                }
                Section {
                    Button(nearby.scanning ? "Stop" : "Scan This Network",
                           systemImage: nearby.scanning ? "stop.circle" : "dot.radiowaves.left.and.right") {
                        if nearby.scanning { nearby.stopScan() } else { nearby.scan() }
                    }
                    .disabled(nearby.addresses == nil)
                    .help(nearby.scanning ? "Stop scanning" : nearby.addresses == nil ? "Join a Wi-Fi or wired network to scan it"
                          : "Try each address on this network for a server that answers on port 22")
                    if let total = nearby.addresses?.count, nearby.next > 0 {
                        ProgressView(value: Double(nearby.scanned), total: Double(total)) {
                            Text("\(nearby.scanned) of \(total)")
                        }
                        if !nearby.scanning, nearby.scanned == total, nearby.answers.isEmpty {
                            Text("No server answered on port 22. You can still add one by its address and port.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(nearby.answers) { answer in
                        Button { onChoose(SSHHost(hostname: answer.address, auth: .password)) } label: {
                            VStack(alignment: .leading) {
                                Text(answer.address).foregroundStyle(Color.primary)
                                if let banner = answer.banner {
                                    Text(banner).font(.caption.monospaced()).foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        .help("Add this server with its address filled in")
                    }
                } header: {
                    Text("Scan")
                } footer: {
                    Text(scanCaption)
                }
            }
            .navigationTitle("Nearby Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done", systemImage: "checkmark") { dismiss() }
                    .help("Close nearby servers")
            }
            .alert("Can't reach the server", isPresented: Binding(get: { unreachable != nil }, set: { if !$0 { unreachable = nil } }),
                   presenting: unreachable) { _ in
                Button("OK") {}
            } message: { name in
                Text("“\(name)” didn't answer. Check that it's on, then try again.")
            }
        }
        .onAppear {
            nearby.browse()
            nearby.findNetwork()
        }
        .onDisappear { nearby.stop() }
    }

    private var scanCaption: String {
        guard let addresses = nearby.addresses, let first = addresses.first, let last = addresses.last else {
            return "This device isn't on a Wi-Fi or wired network. Join one to scan it."
        }
        return "Tries each address from \(first) to \(last) for a server that answers on port 22 (SSH)."
            + (nearby.capped ? " Your network is larger, so only these \(addresses.count) are tried." : "")
    }

    private func choose(_ name: String) {
        guard resolving == nil else { return }
        resolving = name
        nearby.host(for: name) { host in
            resolving = nil
            if let host { onChoose(host) } else { unreachable = name }
        }
    }
}

/// What NearbyView shows. Network calls back on the main queue.
@Observable final class Nearby {
    /// A server that answered Scan, with the first line it sent ("SSH-2.0-OpenSSH_9.6") if that came in time.
    struct Answer: Identifiable {
        let address: String
        var banner: String?
        var id: String { address }
    }

    /// The Bonjour services looked for (Info.plist's NSBonjourServices) and what each offers, in plain words.
    private static let kinds = [(type: "_ssh._tcp", offers: "SSH"), (type: "_sftp-ssh._tcp", offers: "SFTP")]
    /// The announced servers' names, by service type.
    private var found: [String: Set<String>] = [:]
    /// iOS doesn't let AirSCP look on the local network (Settings ▸ Privacy & Security ▸ Local Network).
    private(set) var denied = false
    private var browsers: [NWBrowser] = []

    /// The addresses Scan tries; nil without a Wi-Fi or wired network. `capped`: the network is larger.
    private(set) var addresses: [String]?
    private(set) var capped = false
    private(set) var answers: [Answer] = []
    /// Addresses started and finished.
    private(set) var next = 0
    private(set) var scanned = 0
    private var probes: [NWConnection] = []
    var scanning: Bool { !probes.isEmpty }

    /// Each announced server once (a Mac announces both SSH and SFTP), by name.
    var names: [String] {
        Set(found.values.joined()).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func offers(_ name: String) -> String {
        ListFormatter.localizedString(byJoining: Self.kinds.filter { found[$0.type]?.contains(name) == true }.map(\.offers))
    }

    func browse() {
        for kind in Self.kinds {
            let browser = NWBrowser(for: .bonjour(type: kind.type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.found[kind.type] = Set(results.compactMap { result -> String? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return name
                })
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.denied = false
                case let .waiting(error), let .failed(error):
                    if error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) { self?.denied = true }
                default:
                    break
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        stopScan()
    }

    /// An announced server as a server to add, given to `done` on the main queue: its Bonjour host name
    /// ("studio.local", which getaddrinfo resolves and which stays when the router hands out another address) and
    /// port. nil when it doesn't answer.
    func host(for name: String, done: @escaping (SSHHost?) -> Void) {
        let type = Self.kinds.first { found[$0.type]?.contains(name) == true }?.type ?? Self.kinds[0].type
        DispatchQueue.global().async {
            let target = Self.resolve(name, type: type)
            DispatchQueue.main.async {
                done(target.map { SSHHost(label: name, hostname: $0.host, port: $0.port == 22 ? nil : $0.port, auth: .password) })
            }
        }
    }

    /// Waits up to 5 s for Bonjour's answer: call it off the main queue.
    private static func resolve(_ name: String, type: String) -> (host: String, port: Int)? {
        var target: (host: String, port: Int)?
        return withUnsafeMutablePointer(to: &target) { pointer in
            var ref: DNSServiceRef?
            guard DNSServiceResolve(&ref, 0, 0, name, type, "local.", { _, _, _, error, _, host, port, _, _, context in
                guard error == kDNSServiceErr_NoError, let host, let context else { return }
                context.assumingMemoryBound(to: (host: String, port: Int)?.self).pointee =
                    (String(cString: host).trimmingCharacters(in: CharacterSet(charactersIn: ".")), Int(UInt16(bigEndian: port)))
            }, pointer) == kDNSServiceErr_NoError, let ref else { return nil }
            defer { DNSServiceRefDeallocate(ref) }
            var reply = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
            guard poll(&reply, 1, 5000) == 1, DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { return nil }
            return pointer.pointee
        }
    }

    // MARK: Scan

    func findNetwork() {
        let range = Self.localRange()
        addresses = range.map { ($0.first...$0.last).map { "\($0 >> 24).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)" } }
        capped = range?.capped ?? false
    }

    func scan() {
        findNetwork()
        answers = []
        next = 0
        scanned = 0
        for _ in 0..<32 { probeNext() }  // 32 at a time
    }

    func stopScan() {
        let stopping = probes
        probes = []  // their ends neither count nor start the next
        stopping.forEach { $0.cancel() }
    }

    /// Connects to port 22 at the next address for 1.5 s at most, and reads the server's first line if it comes.
    private func probeNext() {
        guard let addresses, next < addresses.count else { return }
        let address = addresses[next]
        next += 1
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 22, using: .tcp)
        probes.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return connection.cancel() }
            switch state {
            case .ready:
                answers.append(Answer(address: address))
                answers.sort { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 255) { [weak self] data, _, _, _ in
                    if let line = data.flatMap({ String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isNewline).first }),
                       let index = self?.answers.firstIndex(where: { $0.address == address }) {
                        self?.answers[index].banner = String(line)
                    }
                    connection.cancel()
                }
            case .waiting, .failed:
                connection.cancel()
            case .cancelled:  // once, however it ended
                guard let index = probes.firstIndex(where: { $0 === connection }) else { return }  // stopped
                probes.remove(at: index)
                scanned += 1
                probeNext()
            default:
                break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { connection.cancel() }
    }

    /// This device's IPv4 network on Wi-Fi or Ethernet (en0 first), as the range to scan: all of it up to a /24,
    /// else the /24 around its address (`capped`). nil without one.
    private static func localRange() -> (first: UInt32, last: UInt32, capped: Bool)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        let ipv4 = { (address: UnsafeMutablePointer<sockaddr>) in
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        var own: (address: UInt32, mask: UInt32)?
        for entry in sequence(first: list, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET), let mask = entry.pointee.ifa_netmask,
                  ipv4(address) >> 16 != 0xA9FE  // 169.254.x.x: self-assigned, no network
            else { continue }
            if own == nil || name == "en0" { own = (ipv4(address), ipv4(mask)) }
        }
        guard let own else { return nil }
        let mask = max(own.mask, 0xFFFF_FF00)  // at most 254 addresses
        let network = own.address & mask, broadcast = network | ~mask
        guard broadcast - network >= 2 else { return nil }  // a /31 or /32 has no neighbours
        return (network + 1, broadcast - 1, own.mask < 0xFFFF_FF00)
    }
}
