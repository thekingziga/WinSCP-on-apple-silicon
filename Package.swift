// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSCP",
    platforms: [.macOS(.v14)],
    targets: [
        // Protocol + engine layer. Port of WinSCP's source/core, minus the
        // Embarcadero RTL. No third-party dependencies: the SSH transport is
        // the system OpenSSH client driving the `sftp` subsystem.
        .target(
            name: "SFTPKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Session model + transfer semantics. Port of SessionData.cpp,
        // FileMasks.cpp, CopyParam.cpp.
        .target(
            name: "CoreKit",
            dependencies: ["SFTPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Application state and behaviour. A library rather than part of the
        // executable so tests can import and drive it — an executable target
        // cannot be imported.
        .target(
            name: "AppCore",
            dependencies: ["SFTPKit", "CoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI front end. Replaces source/forms + source/packages entirely.
        .executableTarget(
            name: "MacSCP",
            dependencies: ["SFTPKit", "CoreKit", "AppCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ships neither XCTest nor Swift Testing, so the
        // suite is a plain executable: `swift run MacSCPTests`.
        .executableTarget(
            name: "MacSCPTests",
            dependencies: ["SFTPKit", "CoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // End-to-end exercise against a real server:
        // `swift run MacSCPLiveTest <target> [port] [ssh options...]`
        .executableTarget(
            name: "MacSCPLiveTest",
            dependencies: ["SFTPKit", "CoreKit", "AppCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
