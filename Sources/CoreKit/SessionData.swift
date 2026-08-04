import Foundation

/// A saved connection.
///
/// Port of the subset of WinSCP `source/core/SessionData.cpp` that still makes
/// sense here. Everything WinSCP stores about credentials is deliberately
/// absent: authentication is delegated to OpenSSH, so keys, passphrases, and
/// agent state live in the user's existing ssh configuration and Keychain
/// rather than in this app's storage.
public struct SessionData: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var hostName: String
    public var userName: String
    public var portNumber: Int
    public var remoteDirectory: String
    public var localDirectory: String
    /// Extra `-o` style arguments handed to ssh verbatim.
    public var sshOptions: [String]

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostName: String = "",
        userName: String = "",
        portNumber: Int = 22,
        remoteDirectory: String = "",
        localDirectory: String = "",
        sshOptions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.userName = userName
        self.portNumber = portNumber
        self.remoteDirectory = remoteDirectory
        self.localDirectory = localDirectory
        self.sshOptions = sshOptions
    }

    /// The `[user@]host` argument for ssh.
    public var sshTarget: String {
        userName.isEmpty ? hostName : "\(userName)@\(hostName)"
    }

    /// Title shown in the session list; falls back to the target.
    public var displayName: String {
        name.isEmpty ? sshTarget : name
    }

    public var isValid: Bool {
        !hostName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Persists sessions to Application Support as JSON.
///
/// WinSCP uses the Windows registry (`HierarchicalStorage.cpp`); the macOS
/// equivalent is a plist or JSON in the app's container.
public final class SessionStore: @unchecked Sendable {
    public static let shared = SessionStore()

    private let queue = DispatchQueue(label: "MacSCP.SessionStore")
    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacSCP", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.url = base.appendingPathComponent("sessions.json")
        }
    }

    public func load() -> [SessionData] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([SessionData].self, from: data)) ?? []
        }
    }

    public func save(_ sessions: [SessionData]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(sessions) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
