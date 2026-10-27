import AppKit
import DockCore
import ControlModules
import SceneGeneral
import SceneSynth
import SceneVibeCoding
import SwiftUI

@main
struct StreamDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(connection: appDelegate.controller.connection)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)

        Window("律动可视化", id: "glow-scope") {
            GlowScopeView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// OBS lives in general controls, so its status light belongs to that scene; the Codex and
    /// Claude reminders belong to VibeCoding.
    private let general = makeGeneralScene()
    private let vibeCoding = makeVibeCodingScene()
    lazy var controller = DockController(scenes: [general, vibeCoding, makeSynthScene()])
    private var activity: NSObjectProtocol?
    private var displayPower: DisplayPowerMonitor?
    private var obsLights: OBSLightMonitor?
    private var agents: AgentMonitor?

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
        displayPower = DisplayPowerMonitor { [weak self] asleep in self?.controller.setDisplaysSleeping(asleep) }
        controller.requestDisplayWake = { [weak self] in self?.displayPower?.requestWake() }
        displayPower?.start()
        controller.start()
        obsLights = OBSLightMonitor(center: general.activities)
        obsLights?.start()
        agents = AgentMonitor(center: vibeCoding.activities)
        agents?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayPower?.stop()
        HAClient.shared.disconnect()
        obsLights?.stop()
        agents?.stop()
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
