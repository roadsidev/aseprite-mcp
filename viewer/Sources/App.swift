import SwiftUI

@main
struct PixelLiveApp: App {
    @State private var model = LiveModel(directory: PixelLiveApp.liveDirectory())

    var body: some Scene {
        Window("Pixel Live", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 220, minHeight: 240)
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 380, height: 440)
        .windowResizability(.contentMinSize)
    }

    /// --live-dir <path>, else the LiveDirectory default, else the MCP workspace.
    static func liveDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--live-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: "LiveDirectory") {
            return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: ("~/Projects/Personal/pixel-mcp/.live" as NSString).expandingTildeInPath,
                   isDirectory: true)
    }
}
