import AppKit
import ServiceManagement

/// Whether macOS starts the app with your Mac. The registration names the bundle's location, so it
/// has to be set again once the app moves.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.informativeText = "This usually works only once the app is in /Applications."
            alert.runModal()
        }
    }
}
