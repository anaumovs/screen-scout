import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct ScreenScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Screen Scout") {
            ContentView(model: model).preferredColorScheme(.dark)
                .onAppear {
                    if CommandLine.arguments.contains("--request-permissions") { model.requestPermissions() }
                    if let index = CommandLine.arguments.firstIndex(of: "--verify-external"), CommandLine.arguments.count > index + 1 {
                        ExternalVerification(model: model, reportPath: CommandLine.arguments[index + 1]).begin()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
