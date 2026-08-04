import SwiftUI
import AppCore
import CoreKit

/// Login dialog. Port of WinSCP's Login form, with the credential fields
/// removed on purpose: authentication is OpenSSH's job here, so keys,
/// passphrases, agent state, and `~/.ssh/config` host aliases all apply
/// without this app ever handling a secret.
struct ConnectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SessionData()
    @State private var optionsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                savedSessions
                Divider()
                form
            }
            Divider()
            buttons
        }
        .frame(width: 720, height: 420)
        .onAppear {
            if draft.hostName.isEmpty, let first = model.sessions.first {
                load(first)
            }
        }
    }

    // MARK: - Saved sessions

    private var savedSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved sessions")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List {
                ForEach(model.sessions) { item in
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName).lineLimit(1)
                            Text(item.sshTarget)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { load(item) }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            model.deleteSession(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if model.sessions.isEmpty {
                Text("No saved sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(width: 230)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection")
                    .font(.headline)

                labelled("Host name") {
                    TextField("example.com or an ssh_config alias", text: $draft.hostName)
                }
                labelled("User name") {
                    TextField("defaults to your ssh config", text: $draft.userName)
                }
                labelled("Port") {
                    TextField("22", value: $draft.portNumber, format: .number)
                        .frame(width: 90)
                }
                labelled("Session name") {
                    TextField("optional label", text: $draft.name)
                }

                Divider().padding(.vertical, 2)

                Text("Directories")
                    .font(.headline)

                labelled("Remote") {
                    TextField("login directory", text: $draft.remoteDirectory)
                }
                labelled("Local") {
                    TextField("current local directory", text: $draft.localDirectory)
                }

                Divider().padding(.vertical, 2)

                Text("Advanced")
                    .font(.headline)

                labelled("ssh options") {
                    TextField("e.g. -o ProxyJump=bastion", text: $optionsText)
                }

                Text("Authentication uses your existing OpenSSH configuration — keys, ssh-agent, Keychain passphrases, and ~/.ssh/config all apply. Password-only servers are not supported in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .padding(16)
        }
    }

    private func labelled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Button("Save") {
                var toSave = draft
                toSave.sshOptions = parsedOptions
                model.saveSession(toSave)
                draft = toSave
            }
            .disabled(!draft.isValid)

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Connect") {
                var data = draft
                data.sshOptions = parsedOptions
                dismiss()
                Task { await model.connect(data) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(12)
    }

    private var parsedOptions: [String] {
        optionsText
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func load(_ item: SessionData) {
        draft = item
        optionsText = item.sshOptions.joined(separator: " ")
    }
}
