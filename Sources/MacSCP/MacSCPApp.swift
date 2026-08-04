import SwiftUI
import AppCore
import AppKit

@main
struct MacSCPApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacSCP") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Connect…") { model.showingConnectSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Both Panes") {
                    model.refreshLocal()
                    Task { await model.refreshRemote() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
