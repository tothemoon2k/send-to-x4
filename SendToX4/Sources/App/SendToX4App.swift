import SwiftUI
import SendToX4Core

@main
struct SendToX4App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appState)
                .frame(minWidth: 320, idealWidth: 360)
        } label: {
            Image(systemName: appState.x4Reachable ? "book.closed.fill" : "book.closed")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 420)
        }
    }
}
