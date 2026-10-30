// swift-tools-version:5.9
import Foundation
import PackageDescription

/// FreeRDP and OpenSSL as one static library, built by scripts/build-freerdp.sh (build.sh runs it when it's missing).
let freerdp = Context.packageDirectory + "/vendor/out/universal"
/// libssh2 for the iOS app (and the tests that run it on this Mac), built by scripts/build-libssh2.sh when it's there.
let ssh2 = FileManager.default.fileExists(atPath: Context.packageDirectory + "/vendor/ssh2/CSSH2.xcframework")

let package = Package(
    name: "AirSCP",
    // iOS: the iPhone and iPad app (ios/, built with Xcode) uses AirSCPCore, without Remote Desktop.
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [.library(name: "AirSCPCore", targets: ["AirSCPCore"])],
    targets: [
        // Runs a program on a pseudo-terminal (scp only shows progress there). Swift can't fork, and posix_spawn
        // can't give the child a controlling terminal, so this one function is C.
        .target(name: "CPTY"),
        // The RDP client: a C shim over FreeRDP, and AirSCP's two uses of its OpenSSL (airscp_crypto.c: Argon2 for
        // PuTTY keys, a company certificate authority). Its public headers include no FreeRDP or OpenSSL headers.
        .target(
            name: "CRDP",
            cSettings: [.unsafeFlags(["-I\(freerdp)/include/freerdp3", "-I\(freerdp)/include/winpr3",
                                      "-I\(freerdp)/include", "-Wno-deprecated-declarations"])],
            linkerSettings: [
                .unsafeFlags(["-L\(freerdp)/lib"]),
                .linkedLibrary("airscp-rdp"),
                .linkedFramework("CoreFoundation"), .linkedFramework("Foundation"), .linkedFramework("IOKit"),
                .linkedFramework("Carbon"), .linkedFramework("CoreServices"),
            ]),
        .target(name: "AirSCPCore", dependencies: ["CPTY", .target(name: "CRDP", condition: .when(platforms: [.macOS]))]),
        .executableTarget(name: "AirSCP", dependencies: ["AirSCPCore"]),
        // The app's own checks (AppTests.swift) share the core tests' throwaway-sshd harness, so one target tests both.
        .testTarget(name: "AirSCPTests", dependencies: ["AirSCPCore", "AirSCP"] + (ssh2 ? ["AirSCPSSH2"] : [])),
    ]
)

// SSH without macOS's ssh: libssh2 under AirSCPCore's `RemoteTransport`. The Mac app doesn't link it.
if ssh2 {
    package.products.append(.library(name: "AirSCPSSH2", targets: ["AirSCPSSH2"]))
    package.targets += [
        .binaryTarget(name: "CSSH2", path: "vendor/ssh2/CSSH2.xcframework"),
        .target(name: "AirSCPSSH2", dependencies: ["AirSCPCore", "CSSH2"]),
    ]
}
