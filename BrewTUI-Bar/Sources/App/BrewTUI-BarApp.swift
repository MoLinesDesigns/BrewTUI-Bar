import SwiftUI

@main
struct BrewTUIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        _ = AppLocalization.shared
    }

    var body: some Scene {
        Settings {
            appDelegate.settingsView
        }
    }
}
