import AirSCPCore
import AppKit
import Network
import Security
import SwiftUI
import UniformTypeIdentifiers

/// Tools ▸ Certificate Manager: certificates, keys, requests, PKCS#12 files and Java keystores opened (Open… or a
/// drop), their details, and the files made of them (PEM, DER, the chain, keys with or without a passphrase, public
/// keys, PKCS#12 and JKS keystores, truststores), new requests and self-signed certificates, and chain checks, each
/// with the openssl or keytool command that does the same. View Server Certificate… shows the chain a TLS server
/// sends. Nothing is overwritten: Save panels ask, as everywhere on the Mac, and New… never replaces a file.
@MainActor
final class CertificateManagerWindowController: NSWindowController {
    let model = CertificateModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Certificate Manager"
        window.minSize = NSSize(width: 820, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: CertificateManagerView(model: model))
        window.open(size: NSSize(width: 980, height: 620))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class CertificateModel: ObservableObject {
    /// A file (or server) opened, and what it holds.
    struct Source: Identifiable {
        let id = UUID()
        let title: String
        /// The file's path (nil for a server).
        let path: String?
        var items: [PKI.Item]
        /// A server's chain: whether this Mac trusts it, and why not.
        var trust: String?
    }

    @Published var sources: [Source] = []
    @Published var selection: PKI.Item.ID?
    /// The last action's openssl command, for Copy Command.
    @Published var command: String?
    @Published var status: String?
    /// A file that needs a password: asked in a sheet. `keyAlias`: a keystore key's own password.
    @Published var asking: (url: URL, wrong: Bool, keyAlias: String?, storePassword: String?)?
    /// View Server Certificate… asked for a server.
    @Published var askServer = false
    /// What Verify… found, by certificate.
    @Published var checks: [PKI.Item.ID: (valid: Bool, text: String)] = [:]

    var selected: PKI.Item? { sources.lazy.flatMap(\.items).first { $0.id == selection } }
    var allItems: [PKI.Item] { sources.flatMap(\.items) }

    /// Opens `url`, asking for a password when it needs one.
    func open(_ url: URL, password: String? = nil, keyPassword: String? = nil) {
        do {
            let data = try Data(contentsOf: url)
            let items = try PKI.read(data, password: password, keyPassword: keyPassword)
            sources.removeAll { $0.path == url.path }
            sources.append(Source(title: url.lastPathComponent, path: url.path, items: items))
            selection = items.first?.id
            let keystore = data.prefix(4) == Data([0xFE, 0xED, 0xFE, 0xED])
            let isPKCS12 = !keystore && password != nil && !(String(data: data.prefix(4096), encoding: .utf8)?.contains("-----BEGIN") ?? false)
            command = keystore ? PKI.Command.keystoreRead(url.path) : isPKCS12 ? PKI.Command.pkcs12Read(url.path)
                : items.first.map { PKI.Command.show(url.path, kind: $0.kind) }
            status = "Opened \(url.lastPathComponent): " + Self.count(items)
        } catch PKI.ReadError.password {
            asking = (url, password != nil, nil, nil)
        } catch PKI.ReadError.keyPassword(let alias) {
            asking = (url, keyPassword != nil, alias, password)
        } catch PKI.ReadError.unsupported(let what) {
            status = "Can't open \(url.lastPathComponent): AirSCP doesn't read \(what)."
        } catch PKI.ReadError.unknown {
            status = "\(url.lastPathComponent) holds no certificate, key or request that AirSCP knows (PEM, DER, PKCS#7, PKCS#12, JKS)."
        } catch {
            status = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    static func count(_ items: [PKI.Item]) -> String {
        let names = [(PKI.Kind.certificate, "certificate"), (.privateKey, "private key"), (.request, "request"), (.publicKey, "public key")]
        return names.compactMap { kind, name in
            let count = items.filter { $0.kind == kind }.count
            return count == 0 ? nil : "\(count) \(name)\(count == 1 ? "" : "s")"
        }.joined(separator: ", ")
    }

    func close(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        if selected == nil { selection = sources.first?.items.first?.id }
    }

    // MARK: What goes with what

    /// The private key loaded for a certificate or request (same public key), if any.
    func key(for item: PKI.Item) -> PKI.Item? {
        allItems.first { $0.kind == .privateKey && PKI.matches($0, item) }
    }

    /// The certificate loaded for a key, if any.
    func certificate(for key: PKI.Item) -> PKI.Item? {
        allItems.first { $0.kind == .certificate && PKI.matches(key, $0) }
    }

    /// The chain above a certificate, from what is loaded: each issuer in turn, by signature.
    func chain(above certificate: PKI.Item) -> [PKI.Item] {
        var chain: [PKI.Item] = [], current = certificate
        let certificates = allItems.filter { $0.kind == .certificate }
        while let issuer = certificates.first(where: { $0.der != current.der && !chain.contains($0) && PKI.signed(current, by: $0) }) {
            chain.append(issuer)
            if PKI.details(issuer).selfIssued { break }
            current = issuer
        }
        return chain
    }

    // MARK: Saving

    /// A Save panel for `name`; `data` makes the file's bytes. The status says what was saved; the command shows.
    func save(_ name: String, types: [UTType], command: @escaping (String) -> String, from window: NSWindow?,
              data: @escaping () throws -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.isExtensionHidden = false
        Panels.run(panel, on: window) { [self] urls in
            guard let url = urls.first else { return }
            do {
                let bytes = try data()
                if ["key", "p12", "pfx", "jks"].contains(url.pathExtension) {
                    // Keys only for the user, from the start: a new file, unreadable to others before anything is in
                    // it, in place of the one the panel said to replace (which others may have open).
                    unlink(url.path)
                    try PKI.saveNew([(url.path, bytes, 0o600)])
                } else {
                    try bytes.write(to: url, options: .atomic)
                }
                status = "Saved \(url.lastPathComponent)"
                self.command = command(url.path)
            } catch {
                status = "Can't save \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: New requests and certificates

    /// New…: a Save panel for the request or certificate, the key beside it as <name>.key; both are new files.
    func create(_ new: PKI.NewCertificate, passphrase: String, from window: NSWindow?) {
        let what = new.selfSigned ? "certificate" : "request", type = new.selfSigned ? "crt" : "csr"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = new.commonName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "*", with: "wildcard") + "." + type
        panel.allowedContentTypes = [UTType(filenameExtension: type) ?? .data]
        panel.isExtensionHidden = false
        panel.message = "Where to save the \(what). Its private key goes beside it, as a .key file."
        Panels.run(panel, on: window) { [self] urls in
            guard let url = urls.first else { return }
            var keyURL = url.deletingPathExtension().appendingPathExtension("key")
            if keyURL == url { keyURL = url.appendingPathExtension("key") }
            status = "Making a \(new.keyType.title) key…"
            Task {
                guard let made = await Task.detached(priority: .userInitiated, operation: { new.make() }).value,
                      let key = PKI.keyPEM(made.key, passphrase: passphrase) else {
                    status = "OpenSSL couldn't make the \(what)."
                    return
                }
                do {
                    try PKI.saveNew([(keyURL.path, Data(key.utf8), 0o600), (url.path, Data(PKI.pem(made.item).utf8), 0o644)])
                } catch {
                    status = "Nothing saved: " + ((error as? AirSCPError)?.message ?? error.localizedDescription)
                    return
                }
                sources.removeAll { $0.path == url.path }
                sources.append(Source(title: url.lastPathComponent, path: url.path, items: [made.item, made.key]))
                selection = made.item.id
                command = PKI.Command.newCertificate(new, key: keyURL.path, output: url.path, passphrase: !passphrase.isEmpty)
                status = "Saved \(url.lastPathComponent) and its key, \(keyURL.lastPathComponent)"
                    + (new.selfSigned ? "." : ". Send the request to your certificate authority; keep the key.")
            }
        }
    }

    // MARK: Checking a chain

    /// Verify…: `certificate` with the certificates open here as its chain, against a CA bundle's certificates or
    /// those this Mac trusts, for `host` when one is typed.
    func verify(_ certificate: PKI.Item, bundle: URL?, host: String) {
        var authorities: [PKI.Item]?
        if let bundle {
            do {
                authorities = try PKI.read(try Data(contentsOf: bundle)).filter { $0.kind == .certificate }
            } catch PKI.ReadError.password {
                status = "\(bundle.lastPathComponent) has a password: choose a PEM, DER or P7B file of the authorities."
                return
            } catch {
                authorities = []
            }
            guard authorities?.isEmpty == false else {
                status = "\(bundle.lastPathComponent) holds no certificates that AirSCP reads (PEM, DER, P7B)."
                return
            }
        }
        let others = allItems.filter { $0.kind == .certificate && $0.der != certificate.der }
        let host = host.trimmingCharacters(in: .whitespaces)
        let trusted = bundle.map { "in \($0.lastPathComponent)" } ?? "that this Mac trusts"
        Task {
            let check = await Task.detached(priority: .userInitiated) {
                PKI.verify(certificate, others: others, authorities: authorities, host: host)
            }.value
            let result: (valid: Bool, text: String)
            switch check {
            case .valid(let authority):
                result = (true, "Valid\(host.isEmpty ? "" : " for \(host)"): it leads to “\(authority)”, an authority \(trusted).")
            case .expired: result = (false, "Not valid: it, or a certificate above it, has expired or isn't valid yet.")
            case .unknownIssuer:
                result = (false, "Not valid: unknown issuer. It doesn't lead to an authority \(trusted). If certificates "
                          + "between them are missing, open them too.")
            case .nameMismatch:
                let names = PKI.details(certificate).sans.map { $0.replacingOccurrences(of: "DNS:", with: "") }
                result = (false, "Not valid for \(host): the certificate is for " + (names.isEmpty ? "another name." : names.joined(separator: ", ") + "."))
            case .invalid(let reason): result = (false, "Not valid: \(reason)")
            }
            checks[certificate.id] = result
            status = result.text
            command = PKI.Command.verify((PKI.Details.commonName(PKI.details(certificate).subject) ?? "certificate") + ".pem",
                                         chain: !others.isEmpty, authorities: bundle?.path, host: host.isEmpty ? nil : host)
        }
    }

    // MARK: A server's certificates

    /// The certificate chain `host`:`port` sends in a TLS handshake, and whether this Mac trusts it for that name.
    func viewServer(_ host: String, port: Int) async {
        status = "Connecting to \(host):\(port)…"
        do {
            let (certificates, trust) = try await Self.serverChain(host: host, port: port)
            let items = certificates.map { PKI.Item(kind: .certificate, der: $0) }
            sources.removeAll { $0.path == nil && $0.title == "\(host):\(port)" }
            sources.append(Source(title: "\(host):\(port)", path: nil, items: items, trust: trust))
            selection = items.first?.id
            command = PKI.Command.server(host, port)
            status = "\(host):\(port) sent \(items.count) certificate\(items.count == 1 ? "" : "s"). " + trust
        } catch {
            status = "Can't get the certificate of \(host):\(port): \(error.localizedDescription)"
        }
    }

    /// A TLS handshake that accepts any certificate (it only looks), then the chain and this Mac's verdict.
    static func serverChain(host: String, port: Int) async throws -> (certificates: [Data], trust: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw AirSCPError(.other, "Not a port: \(port)") }
        let tls = NWProtocolTLS.Options()
        final class Box: @unchecked Sendable { var certificates: [Data] = []; var trust = "" }
        let box = Box()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            box.certificates = chain.map { SecCertificateCopyData($0) as Data }
            var error: CFError?
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            box.trust = SecTrustEvaluateWithError(trust, &error) ? "This Mac trusts it for \(host)."
                : "This Mac doesn't trust it: " + ((error.map { CFErrorCopyDescription($0) as String }) ?? "unknown reason") + "."
            complete(true)
        }, DispatchQueue.global())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: tls))
        // Ends once, on the main queue: ready, failed (the chain may have come anyway), or 20 seconds.
        final class Once: @unchecked Sendable {
            var continuation: CheckedContinuation<(certificates: [Data], trust: String), Error>?
            let connection: NWConnection
            init(_ connection: NWConnection) { self.connection = connection }
            func finish(_ result: Result<(certificates: [Data], trust: String), Error>) {
                guard let continuation else { return }
                self.continuation = nil
                connection.cancel()
                continuation.resume(with: result)
            }
        }
        let once = Once(connection)
        return try await withCheckedThrowingContinuation { continuation in
            once.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success((box.certificates, box.trust)))
                case .failed(let error), .waiting(let error):
                    once.finish(box.certificates.isEmpty ? .failure(error) : .success((box.certificates, box.trust)))
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                once.finish(.failure(AirSCPError(.timeout, "No TLS answer within 20 seconds.")))
            }
        }
    }
}

struct CertificateManagerView: View {
    @ObservedObject var model: CertificateModel
    @State private var dropTargeted = false
    @State private var password = ""
    @State private var server = ""
    @State private var exporting: Exporting?
    @State private var creating = false
    @State private var trusting: PKI.Item?
    @State private var verifying: PKI.Item?
    @Environment(\.colorScheme) private var scheme

    /// The sheet for a key or a keystore: a passphrase (and for PKCS#12 or JKS a name; for PKCS#12 the legacy switch).
    struct Exporting: Identifiable {
        let id = UUID()
        let pkcs12: Bool
        let item: PKI.Item
        var passphrase = ""
        var name = ""
        var legacy = false
        var traditional = false
        /// A Java keystore (JKS) instead of PKCS#12.
        var jks = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                details.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.open(url) } }
                }
            }
            return true
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).opacity(dropTargeted ? 1 : 0))
        .sheet(isPresented: Binding(get: { model.asking != nil }, set: { if !$0 { model.asking = nil } })) { passwordSheet }
        .sheet(isPresented: $model.askServer) { serverSheet }
        .sheet(item: $exporting) { export in
            ExportSheet(export: export, cancel: { exporting = nil }, save: { saveExport($0, export.item) })
        }
        .sheet(isPresented: $creating) {
            NewCertificateSheet(cancel: { creating = false }) { new, passphrase in
                creating = false
                model.create(new, passphrase: passphrase, from: NSApp.windows.first { $0.title == "Certificate Manager" })
            }
        }
        .sheet(item: $trusting) { selected in
            TruststoreSheet(certificates: truststoreCandidates, chosen: Set(truststoreCandidates.filter {
                $0.der == selected.der || PKI.details($0).isCA || PKI.details($0).selfIssued
            }.map(\.id)), cancel: { trusting = nil }) { chosen, jks, password in
                trusting = nil
                let ext = jks ? "jks" : "p12"
                model.save("truststore." + ext, types: [.init(filenameExtension: ext) ?? .data],
                           command: { PKI.Command.truststore(aliases: PKI.aliases(chosen), output: $0, jks: jks) },
                           from: NSApp.windows.first { $0.title == "Certificate Manager" }) {
                    guard let data = PKI.truststore(chosen, password: password, jks: jks) else {
                        throw AirSCPError(.other, "OpenSSL couldn't make the file.")
                    }
                    return data
                }
            }
        }
        .sheet(item: $verifying) { certificate in
            VerifySheet(title: PKI.title(certificate), cancel: { verifying = nil }) { bundle, host in
                verifying = nil
                model.verify(certificate, bundle: bundle, host: host)
            }
        }
    }

    /// The certificates open here, each once: what a truststore can hold.
    private var truststoreCandidates: [PKI.Item] {
        var seen = Set<Data>()
        return model.allItems.filter { $0.kind == .certificate && seen.insert($0.der).inserted }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").font(.system(size: 36, weight: .light)).foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("No certificates open").font(.headline)
                    Text("Drop a file here, or click Open…: certificates (PEM, CRT, CER, DER), chains (P7B), PKCS#12 (PFX, "
                         + "P12), Java keystores (JKS), private keys and certificate requests. New… makes a certificate "
                         + "request or a self-signed certificate.")
                        .multilineTextAlignment(.center).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.sources) { source in
                        Section(source.title) {
                            ForEach(PKI.chainOrder(source.items.filter { $0.kind == .certificate })
                                    + source.items.filter { $0.kind != .certificate }) { item in
                                row(item).tag(item.id)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("certificates.list")
            }
            Divider()
            HStack {
                Button("Open…", action: chooseFile)
                    .help("Open a certificate, key, request, PKCS#12 file or Java keystore")
                    .accessibilityIdentifier("certificates.open")
                Button("New…") { creating = true }
                    .help("Make a new key with a certificate request (CSR) or a self-signed certificate")
                    .accessibilityIdentifier("certificates.new")
                Button("Server…") { model.askServer = true }
                    .help("See the certificate chain a TLS server sends (HTTPS, LDAPS, SMTPS…)")
                Spacer()
                Button("Close File") {
                    if let source = model.sources.first(where: { $0.items.contains { $0.id == model.selection } }) { model.close(source) }
                }
                .disabled(model.selected == nil)
                .help(model.selected == nil ? "Select something first" : "Take the selected item's file out of the list (the file stays)")
            }
            .padding(8)
        }
    }

    private func row(_ item: PKI.Item) -> some View {
        let details = PKI.details(item)
        let days = item.kind == .certificate ? PKI.daysLeft(details) : nil
        return HStack(spacing: 8) {
            Image(systemName: ["checkmark.seal", "key.fill", "doc.badge.ellipsis", "key"][item.kind.rawValue - 1])
                .foregroundColor(days.map { $0 < 0 ? .red : $0 < 30 ? .orange : .accentColor } ?? .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(PKI.title(item)).lineLimit(1)
                Text(subtitle(item, details, days)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .help(days.map { $0 < 0 ? "Expired \(-$0) days ago" : "Expires in \($0) days" } ?? PKI.title(item))
    }

    private func subtitle(_ item: PKI.Item, _ details: PKI.Details, _ days: Int?) -> String {
        switch item.kind {
        case .certificate:
            let until = details.notAfter.map { "until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            let issued = details.selfIssued ? "self-signed" : "by " + (PKI.Details.commonName(details.issuer) ?? details.issuer)
            return [issued, until, days.map { $0 < 0 ? "expired" : $0 < 30 ? "expires in \($0) days" : "" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .privateKey:
            return model.certificate(for: item).map { "goes with " + PKI.title($0).replacingOccurrences(of: "Certificate: ", with: "") }
                ?? (item.name.map { "“\($0)”" } ?? "no certificate open for it")
        case .request: return details.key
        case .publicKey: return model.allItems.contains { $0.kind != .publicKey && PKI.matches($0, item) } ? "matches an open item" : ""
        }
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        if let item = model.selected {
            let details = PKI.details(item)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PKI.title(item)).font(.title3.bold()).textSelection(.enabled)
                        if let trust = model.sources.first(where: { $0.items.contains(item) })?.trust {
                            Label(trust, systemImage: trust.hasPrefix("This Mac trusts") ? "checkmark.shield" : "exclamationmark.shield")
                                .foregroundColor(trust.hasPrefix("This Mac trusts") ? .green : .orange)
                        }
                        if let check = model.checks[item.id] {
                            Label(check.text, systemImage: check.valid ? "checkmark.shield" : "exclamationmark.shield")
                                .foregroundColor(check.valid ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(fields(item, details), id: \.0) { label, value, color in
                                GridRow {
                                    Text(label).foregroundColor(.secondary).gridColumnAlignment(.trailing)
                                    Text(value).foregroundColor(color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actions(item).padding(10)
            }
        } else {
            Text("Select a certificate or key to see its details").foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fields(_ item: PKI.Item, _ details: PKI.Details) -> [(String, String, Color)] {
        var rows: [(String, String, Color)] = []
        func add(_ label: String, _ value: String?, _ color: Color = .primary) {
            if let value, !value.isEmpty { rows.append((label, value, color)) }
        }
        add("Name in the file", item.name)
        switch item.kind {
        case .certificate:
            add("Subject", details.subject)
            add("Issuer", details.selfIssued ? details.issuer + " (self-signed)" : details.issuer)
            add("Names (SAN)", details.sans.joined(separator: "\n"))
            let days = PKI.daysLeft(details)
            add("Valid from", details.notBefore?.formatted(date: .long, time: .shortened))
            add("Valid until", details.notAfter.map { $0.formatted(date: .long, time: .shortened)
                + (days.map { $0 < 0 ? " — expired" : " — in \($0) days" } ?? "") },
                days.map { $0 < 0 ? .red : $0 < 30 ? .orange : .primary } ?? .primary)
            add("Serial number", details.first("serial"))
            add("Key usage", details.first("keyUsage"))
            add("Extended key usage", details.first("extendedKeyUsage"))
            add("Certificate authority", details.isCA ? "Yes" + (details.first("pathLength").map { ", path length \($0)" } ?? "") : "No")
            add("Signature", details.first("signature"))
            add("Public key", details.key)
            add("Private key", model.key(for: item) != nil ? "Open (it matches)" : "Not open")
            add("Issued by (open)", PKI.chainOrder([item] + model.chain(above: item)).dropFirst().first.map(PKI.title))
            add("SHA-256", PKI.fingerprint(item.der))
            add("SHA-1", PKI.fingerprint(item.der, sha1: true))
        case .request:
            add("Subject", details.subject)
            add("Names (SAN)", details.sans.joined(separator: "\n"))
            add("Signature", details.first("signature") .map { $0 + (details.first("verified") == "yes" ? " (valid)" : " (doesn't verify)") })
            add("Public key", details.key)
        case .privateKey, .publicKey:
            add("Type", details.key)
            add("Certificate", model.certificate(for: item).map(PKI.title) ?? "None open matches it")
            if let publicKey = PKI.publicKey(item) { add("Public key SHA-256", PKI.fingerprint(publicKey)) }
        }
        return rows
    }

    @ViewBuilder
    private func actions(_ item: PKI.Item) -> some View {
        let window = NSApp.windows.first { $0.title == "Certificate Manager" }
        let base = (item.name ?? PKI.Details.commonName(PKI.details(item).subject) ?? "certificate")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "*", with: "wildcard")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch item.kind {
                case .certificate:
                    Button("Save PEM…") {
                        model.save(base + ".pem", types: [.init(filenameExtension: "pem") ?? .data], command: { PKI.Command.toPEM("in.der", $0) },
                                   from: window) { Data(PKI.pem(item).utf8) }
                    }
                    .help("Save the certificate as PEM text (.pem, .crt): what most servers and tools want")
                    Button("Save DER…") {
                        model.save(base + ".cer", types: [.init(filenameExtension: "cer") ?? .data], command: { PKI.Command.toDER("in.pem", $0) },
                                   from: window) { item.der }
                    }
                    .help("Save the certificate as binary DER (.cer, .der): for Windows and Java")
                    Button("Save Chain…") {
                        let chain = [item] + model.chain(above: item)
                        model.save(base + "-chain.pem", types: [.init(filenameExtension: "pem") ?? .data], command: { PKI.Command.chain("certificates.pem", $0) },
                                   from: window) { Data(chain.map(PKI.pem).joined().utf8) }
                    }
                    .help("Save the certificate followed by its issuers (the ones open here) as one PEM file, as web servers want")
                case .privateKey:
                    Button("Save Key…") { exporting = Exporting(pkcs12: false, item: item) }
                        .help("Save the private key as PEM, with a passphrase or without one")
                case .request:
                    Button("Save PEM…") {
                        model.save(base + ".csr", types: [.init(filenameExtension: "csr") ?? .data], command: { "openssl req -in in.csr -out " + PKI.Command.q($0) },
                                   from: window) { Data(PKI.pem(item).utf8) }
                    }
                    .help("Save the certificate request as PEM, to send to a certificate authority")
                case .publicKey:
                    EmptyView()
                }
                if item.kind != .publicKey {
                    Button("Public Key…") {
                        guard let key = PKI.publicKey(item) else { return }
                        model.save(base + ".pub.pem", types: [.init(filenameExtension: "pem") ?? .data], command: { PKI.Command.publicKey("in.pem", $0) },
                                   from: window) { Data(PKI.pem(key, label: "PUBLIC KEY").utf8) }
                    }
                    .help("Save only the public key, as PEM")
                }
                Spacer()
            }
            if item.kind == .certificate || item.kind == .privateKey {
                HStack {
                    let partner = item.kind == .certificate ? model.key(for: item) : model.certificate(for: item)
                    let missing = item.kind == .certificate ? "Open the certificate's private key first (its .key or .pem file)"
                        : "Open the key's certificate first"
                    Button("PKCS#12…") { exporting = Exporting(pkcs12: true, item: item, name: base) }
                        .disabled(partner == nil)
                        .help(partner == nil ? missing : "Bundle the certificate, its private key and its chain in a password-protected .p12 (.pfx)")
                    Button("JKS…") { exporting = Exporting(pkcs12: true, item: item, name: base, jks: true) }
                        .disabled(partner == nil)
                        .help(partner == nil ? missing : "Bundle the certificate, its private key and its chain in a Java keystore (.jks) for older Java")
                    if item.kind == .certificate {
                        Button("Truststore…") { trusting = item }
                            .help("Put this and other certificate authorities open here in a truststore (PKCS#12 or JKS) for Java and other apps")
                        Button("Verify…") { verifying = item }
                            .help("Check that the certificate leads to an authority you trust, hasn't expired and fits a host name")
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Sheets

    private var passwordSheet: some View {
        let asking = model.asking
        return VStack(alignment: .leading, spacing: 12) {
            Text(asking?.keyAlias.map { "The key “\($0)” has a password of its own" } ?? "“\(asking?.url.lastPathComponent ?? "")” needs its password")
                .font(.headline)
            Text(asking?.wrong == true ? "That password didn't open it. Try again." : asking?.keyAlias != nil
                 ? "The keystore opened, but this key was saved with another password. Type the key's password."
                 : "It is a PKCS#12 file, a Java keystore or an encrypted key. The password stays in this window only.")
                .font(.callout).foregroundColor(asking?.wrong == true ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).accessibilityIdentifier("certificates.password")
            HStack {
                Spacer()
                Button("Cancel") {
                    password = ""
                    model.asking = nil
                }
                .keyboardShortcut(.cancelAction).help("Don't open the file")
                Button("Open") {
                    guard let asking else { return }
                    let typed = password
                    password = ""
                    model.asking = nil
                    DispatchQueue.main.async {
                        if asking.keyAlias != nil {
                            model.open(asking.url, password: asking.storePassword, keyPassword: typed)
                        } else {
                            model.open(asking.url, password: typed)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).help("Open the file with this password")
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var serverSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View a server's certificate").font(.headline)
            Text("The chain a TLS server sends, and whether this Mac trusts it. Type host:port (443 when left out), e.g. "
                 + "example.com, ldap.example.com:636.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("host:port", text: $server).accessibilityIdentifier("certificates.server")
            HStack {
                Spacer()
                Button("Cancel") { model.askServer = false }.keyboardShortcut(.cancelAction).help("Close without connecting")
                Button("View") {
                    model.askServer = false
                    let (host, port) = Self.hostAndPort(server)
                    Task { await model.viewServer(host, port: port) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Connect to the server and show its certificates (nothing is sent but the handshake)")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// "host", "host:port", "[v6]:port", "https://host/…".
    static func hostAndPort(_ text: String) -> (String, Int) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), let host = url.host, url.scheme != nil { return (host, url.port ?? 443) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? 443 : 443)
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            let port = Int(text[text.index(after: colon)...]) ?? 443
            text = String(text[..<colon])
            return (text, port)
        }
        return (text, 443)
    }

    func saveExport(_ export: Exporting, _ item: PKI.Item) {
        exporting = nil
        let window = NSApp.windows.first { $0.title == "Certificate Manager" }
        if export.jks {
            let certificate = item.kind == .certificate ? item : model.certificate(for: item)
            let key = item.kind == .privateKey ? item : model.key(for: item)
            guard let certificate, let key else { return }
            let chain = model.chain(above: certificate)
            let alias = export.name.trimmingCharacters(in: .whitespaces).isEmpty ? PKI.aliases([certificate])[0] : export.name.lowercased()
            model.save((export.name.isEmpty ? "keystore" : export.name) + ".jks", types: [.init(filenameExtension: "jks") ?? .data],
                       command: { PKI.Command.jks(key: "key.pem", certificate: "certificate.pem", alias: alias, output: $0) },
                       from: window) {
                PKI.jks(key: key, certificate: certificate, chain: chain, name: export.name, password: export.passphrase)
            }
        } else if export.pkcs12 {
            let certificate = item.kind == .certificate ? item : model.certificate(for: item)
            let key = item.kind == .privateKey ? item : model.key(for: item)
            guard let certificate, let key else { return }
            let chain = model.chain(above: certificate)
            model.save((export.name.isEmpty ? "certificate" : export.name) + ".p12", types: [.init(filenameExtension: "p12") ?? .data],
                       command: { PKI.Command.pkcs12(key: "key.pem", certificate: "certificate.pem", output: $0, legacy: export.legacy) },
                       from: window) {
                guard let data = PKI.pkcs12(key: key, certificate: certificate, chain: chain, name: export.name.isEmpty ? nil : export.name,
                                            password: export.passphrase, legacy: export.legacy) else {
                    throw AirSCPError(.other, "OpenSSL couldn't make the file.")
                }
                return data
            }
        } else {
            model.save("private.key", types: [.init(filenameExtension: "key") ?? .data],
                       command: { PKI.Command.key("in.key", $0, passphrase: !export.passphrase.isEmpty, traditional: export.traditional) },
                       from: window) {
                guard let pem = PKI.keyPEM(item, passphrase: export.passphrase, traditional: export.traditional) else {
                    throw AirSCPError(.other, "OpenSSL couldn't write the key.")
                }
                return Data(pem.utf8)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.status ?? "Everything happens on this Mac; passwords and keys never leave it.")
                .font(.callout).foregroundColor(.secondary).lineLimit(2)
            Spacer()
            if let command = model.command {
                Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).foregroundColor(.secondary).frame(maxWidth: 360, alignment: .trailing)
                    .help("The openssl (or keytool) command that does the same: " + command)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .help("Copy the equivalent openssl (or keytool) command, to run it yourself in Terminal")
                .accessibilityIdentifier("certificates.copyCommand")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose certificates, keys, requests, PKCS#12 files or Java keystores."
        Panels.run(panel, on: NSApp.windows.first { $0.title == "Certificate Manager" }) { urls in
            urls.forEach { model.open($0) }
        }
    }
}

/// PKCS#12… (a friendly name, a password, the legacy switch), JKS… (an alias, a password) and Save Key… (a passphrase,
/// the traditional format).
struct ExportSheet: View {
    @State var export: CertificateManagerView.Exporting
    let cancel: () -> Void
    let save: (CertificateManagerView.Exporting) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(export.jks ? "Make a Java keystore (JKS)" : export.pkcs12 ? "Make a PKCS#12 file" : "Save the private key").font(.headline)
            if export.jks {
                Text("The private key, its certificate and the chain open here, in a Java keystore protected by a password. "
                     + "Java 9 and later read PKCS#12 too, the better choice for them.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Alias (optional)", text: $export.name).accessibilityIdentifier("certificates.p12Name")
                    .help("The entry's name in the keystore (lower case, as Java keeps it); the certificate's common name when empty")
                SecureField("Password", text: $export.passphrase).accessibilityIdentifier("certificates.p12Password")
                    .help("Protects the keystore and its key: apps ask for it to open the file")
            } else if export.pkcs12 {
                Text("The private key, its certificate and the chain open here, in one file protected by a password "
                     + "(.p12 or .pfx: Windows, Java, browsers, mail apps).")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Friendly name (optional)", text: $export.name).accessibilityIdentifier("certificates.p12Name")
                    .help("The name Windows and keystores show for the entry")
                SecureField("Password", text: $export.passphrase).accessibilityIdentifier("certificates.p12Password")
                    .help("Protects the file: apps ask for it to open it")
                Toggle("Compatible with older systems", isOn: $export.legacy)
                    .help("3DES and SHA-1 instead of AES-256 and SHA-256: only for Java 8 or Windows before 2019 that refuse the file")
                Text("Only for Java 8 or older Windows that can't open the file otherwise.").font(.caption).foregroundColor(.secondary)
            } else {
                Text("A passphrase encrypts the key (AES-256). Without one, anyone who gets the file can use the key.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Passphrase (optional)", text: $export.passphrase).accessibilityIdentifier("certificates.keyPassphrase")
                    .help("Leave it empty for a key without one. It stays in this window, never in a command line")
                Toggle("Traditional format (PKCS#1 / SEC1)", isOn: $export.traditional)
                    .disabled(!export.passphrase.isEmpty)
                    .help(export.passphrase.isEmpty ? "“BEGIN RSA PRIVATE KEY”: for older software that doesn't read PKCS#8"
                          : "Only without a passphrase: an encrypted key is always PKCS#8")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without saving")
                Button("Save…") { save(export) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(export.pkcs12 && export.passphrase.isEmpty)
                    .help(export.pkcs12 && export.passphrase.isEmpty ? "Type a password first: a \(export.jks ? "keystore" : "PKCS#12 file") needs one"
                          : "Choose where to save it")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// New…: a new key with a certificate request for a certificate authority, or with a self-signed certificate for a TLS
/// server.
struct NewCertificateSheet: View {
    let cancel: () -> Void
    let create: (PKI.NewCertificate, String) -> Void
    @State private var new = PKI.NewCertificate()
    @State private var days = "365"
    @State private var passphrase = ""

    /// The form as typed, with the days read.
    private var made: PKI.NewCertificate {
        var made = new
        made.days = Int(days.trimmingCharacters(in: .whitespaces)) ?? 0
        return made
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New certificate request or self-signed certificate").font(.headline)
            Picker("Make:", selection: $new.selfSigned) {
                Text("Certificate request (CSR)").tag(false)
                Text("Self-signed certificate").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("certificates.newKind")
            .help("A request goes to a certificate authority, which sends the certificate back; a self-signed one works at once")
            FormCaption(new.selfSigned ? "Works at once, but only where you trust it yourself: tests and internal servers."
                        : "Send the request to a certificate authority; it sends back the certificate. Keep the key: it goes with it.")
            Form {
                TextField("Common name:", text: $new.commonName, prompt: Text("web.example.com"))
                    .accessibilityIdentifier("certificates.commonName")
                    .help("Who the certificate is for: usually the server's host name")
                TextField("Other names:", text: $new.otherNames, prompt: Text("Optional: www.example.com, 10.0.0.5"))
                    .accessibilityIdentifier("certificates.names")
                    .help("More host names and IP addresses it is for (subject alternative names), between commas")
                FormCaption("Browsers check these names. The common name goes in too when it is a host name or an address.")
                TextField("Organization:", text: $new.organization, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.organization")
                    .help("Your company or organization")
                TextField("Unit:", text: $new.unit, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.unit")
                    .help("A department, such as IT")
                TextField("City:", text: $new.locality, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.locality")
                    .help("The city or town (locality)")
                TextField("State:", text: $new.state, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.state")
                    .help("The state or province, written out")
                TextField("Country:", text: $new.country, prompt: Text("Optional: two letters, such as US"))
                    .accessibilityIdentifier("certificates.country")
                    .help("The country as two letters: US, GB, DE")
                Picker("Key:", selection: $new.keyType) {
                    ForEach(PKI.KeyType.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("certificates.keyType")
                .help("The new key's type and size; RSA 2048 unless you need another")
                FormCaption("RSA 2048 works with every certificate authority and server. EC keys are smaller and faster; Ed25519 "
                            + "isn't accepted by browsers or public authorities yet.")
                if new.selfSigned {
                    TextField("Valid for (days):", text: $days)
                        .accessibilityIdentifier("certificates.days")
                        .help("How many days the certificate is valid from now; 365 by default")
                    FormCaption("Apple devices refuse server certificates valid for more than 825 days.")
                }
                SecureField("Key passphrase:", text: $passphrase, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.newPassphrase")
                    .help("Encrypts the key file (AES-256). It stays in this window, never in a command line")
                FormCaption("Leave it empty for a server that must start without asking for it.")
            }
            HStack {
                HelpButton(.newCertificate)
                Text(made.problem ?? "").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without making anything")
                Button("Create…") { create(made, passphrase) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(made.problem != nil)
                    .help(made.problem ?? "Choose where to save the \(new.selfSigned ? "certificate" : "request"); its key goes beside it")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Truststore…: the certificate authorities an app should trust, ticked among the certificates open here, in one
/// PKCS#12 or JKS file.
struct TruststoreSheet: View {
    let certificates: [PKI.Item]
    @State var chosen: Set<PKI.Item.ID>
    let cancel: () -> Void
    let save: ([PKI.Item], Bool, String) -> Void
    @State private var jks = false
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make a truststore").font(.headline)
            Text("The certificate authorities an app should trust, in one file protected by a password. Tick what goes in; "
                 + "open more certificates in the window to add them.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(certificates) { item in
                        Toggle(PKI.title(item), isOn: Binding(get: { chosen.contains(item.id) }, set: {
                            if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) }
                        }))
                        .help("Put this certificate in the truststore, or leave it out")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Form {
                Picker("Format:", selection: $jks) {
                    Text("PKCS#12 (.p12)").tag(false)
                    Text("Java keystore (.jks)").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("certificates.trustFormat")
                .help("PKCS#12 by default; JKS only for Java 8 and older")
                FormCaption("PKCS#12 suits Java 9 and later and most other apps; JKS is for older Java.")
                SecureField("Password:", text: $password).accessibilityIdentifier("certificates.trustPassword")
                    .help("Apps ask for it to open the truststore")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without saving")
                Button("Save…") { save(certificates.filter { chosen.contains($0.id) }, jks, password) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(chosen.isEmpty || password.isEmpty)
                    .help(chosen.isEmpty ? "Tick at least one certificate" : password.isEmpty ? "Type a password first: a truststore needs one"
                          : "Choose where to save the truststore")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Verify…: against a CA bundle the person picks or the authorities this Mac trusts, for a host name when one is typed.
struct VerifySheet: View {
    let title: String
    let cancel: () -> Void
    let verify: (URL?, String) -> Void
    @State private var useBundle = false
    @State private var bundle: URL?
    @State private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify “\(title.components(separatedBy: ": ").last ?? title)”").font(.headline)
            Text("Checks that the certificate, with the issuers open here, leads to an authority you trust and that none has "
                 + "expired. Nothing is fetched from the network.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Trust:", selection: $useBundle) {
                    Text("Authorities this Mac trusts").tag(false)
                    Text("A CA bundle file").tag(true)
                }
                .accessibilityIdentifier("certificates.verifyAgainst")
                .help("This Mac's trusted authorities (the Keychain's) by default, or only those in a file you choose")
                if useBundle {
                    LabeledContent("CA bundle:") {
                        HStack {
                            Text(bundle?.lastPathComponent ?? "None chosen").lineLimit(1).truncationMode(.middle)
                                .foregroundColor(bundle == nil ? .secondary : .primary)
                            Button("Choose…", action: chooseBundle)
                                .accessibilityIdentifier("certificates.chooseBundle")
                                .help("Choose a PEM, DER or P7B file with the certificate authorities to trust")
                        }
                    }
                }
                TextField("Host name:", text: $host, prompt: Text("Optional"))
                    .accessibilityIdentifier("certificates.verifyHost")
                    .help("Also check that the certificate is for this name and for TLS servers, as a browser does")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without checking")
                Button("Verify") { verify(useBundle ? bundle : nil, host) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(useBundle && bundle == nil)
                    .help(useBundle && bundle == nil ? "Choose the CA bundle first" : "Check the chain")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the certificate authorities to trust: a PEM, DER or P7B file."
        Panels.run(panel, on: NSApp.windows.first { $0.title == "Certificate Manager" }.map(frontSheet)) { urls in
            if let url = urls.first { bundle = url }
        }
    }
}
