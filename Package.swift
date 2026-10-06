// swift-tools-version:5.9
import PackageDescription

/// FreeRDP and OpenSSL as one static library, built by scripts/build-freerdp.sh (build.sh runs it when it's missing).
let freerdp = Context.packageDirectory + "/vendor/out/universal"

let package = Package(
    name: "AirSCP",
    platforms: [.macOS(.v13)],
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
        .target(name: "AirSCPCore", dependencies: ["CPTY", "CRDP"]),
        .executableTarget(name: "AirSCP", dependencies: ["AirSCPCore"]),
        // The app's own checks (AppTests.swift) share the core tests' throwaway-sshd harness, so one target tests both.
        .testTarget(name: "AirSCPTests", dependencies: ["AirSCPCore", "AirSCP"]),
    ]
)
