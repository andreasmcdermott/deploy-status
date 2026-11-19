import DeployCore
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settingsWindow: NSWindow?

    @MainActor
    func showSettings(store: Store) {
        if settingsWindow == nil {
            let view = Preferences().environmentObject(store)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Deploy Status Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

@main
struct DeployStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Dashboard { delegate.showSettings(store: store) }.environmentObject(store)
        } label: {
            Image(systemName: menuIcon)
                .accessibilityLabel("Deploy Status")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if store.reconnect || !store.errors.isEmpty { return "exclamationmark.icloud" }
        if store.state.readings.values.contains(where: { $0.status.latest?.phase == .failed }) {
            return "exclamationmark.circle"
        }
        if store.state.readings.values.contains(where: { !$0.status.active.isEmpty }) { return "arrow.triangle.2.circlepath" }
        return "shippingbox"
    }
}

extension Phase {
    var symbol: String {
        switch self {
        case .deploying, .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .waiting, .queued: return "clock"
        case .inactive: return "archivebox"
        case .cancelled: return "nosign"
        case .skipped: return "forward.end"
        case .neutral: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .succeeded: return .green
        case .failed: return .red
        case .deploying, .running: return .blue
        default: return .secondary
        }
    }
}
