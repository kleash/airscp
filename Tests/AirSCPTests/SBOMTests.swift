import AirSCPCore
import Foundation
import Testing

// PLAN.md AF: sbom.spdx.json names FreeRDP and OpenSSL exactly as scripts/build-freerdp.sh pins them (and AirSCP's
// VERSION), so the vulnerability scan (security.yml) checks what the app is built from.

@Test func sbomMatchesTheFreeRDPAndOpenSSLPins() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path
    let fresh = try scratch() + "/sbom.spdx.json"
    try await run(["/bin/bash", repo + "/scripts/sbom.sh", fresh])
    // Every line but the time it was written.
    func lines(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.contains("\"created\":") }
    }
    #expect(try lines(fresh) == lines(repo + "/sbom.spdx.json"),
            "sbom.spdx.json doesn't match scripts/build-freerdp.sh and VERSION: run scripts/sbom.sh and commit it")
}
