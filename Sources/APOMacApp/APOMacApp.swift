import SwiftUI

@main
struct APOMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("APOMac") {
            ContentView(model: model)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reload Configuration") { Task { await model.saveAndReload() } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }
}
