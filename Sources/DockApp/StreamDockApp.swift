import AppKit
import DockCore
import SceneGeneral
import SceneSynth
import SceneVibeCoding
import SwiftUI

@main
struct StreamDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(connection: appDelegate.controller.connection)
        }
        .menuBarExtraStyle(.menu)

        Window("StreamDock 设置", id: SettingsView.windowID) {
            SettingsView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DockController(scenes: [makeGeneralScene(), makeVibeCodingScene(), makeSynthScene()])
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the device.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        // Key presses must be handled promptly even though we never have a window in front.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Driving the StreamDock"
        )
        ProcessInfo.processInfo.disableAutomaticTermination("Driving the StreamDock")
        ProcessInfo.processInfo.disableSuddenTermination()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

struct MenuBarIcon: View {
    let connection: DockController.Connection

    var body: some View {
        if case .connected = connection {
            Image(systemName: "square.grid.3x3.fill")
        } else {
            Image(systemName: "square.grid.3x3")
        }
    }
}
