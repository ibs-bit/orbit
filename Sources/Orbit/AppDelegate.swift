import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private var settingsWindow: NSWindow?
    private var accessibilityItem: NSMenuItem!
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        wireWheel()
        monitor.start()
        if !AccessibilityAccess.isTrusted(prompt: true) {
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { return }
                self.refreshAccessibility()
                if AXIsProcessTrusted() {
                    t.invalidate()
                    // Monitors installed before trust was granted don't see key events; reinstall them.
                    self.monitor.stop()
                    self.monitor.start()
                }
            }
        }
        refreshAccessibility()
        if let demo = ProcessInfo.processInfo.environment["ORBIT_DEMO"] {
            let mode = WheelMode(rawValue: ProcessInfo.processInfo.environment["ORBIT_DEMO_MODE"] ?? "") ?? .convert
            let files = demo.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let screen = NSScreen.main?.frame ?? .zero
                WheelController.shared.show(files: files, mode: mode, at: NSPoint(x: screen.midX, y: screen.midY))
                if let snap = ProcessInfo.processInfo.environment["ORBIT_DEMO_SNAPSHOT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        WheelController.shared.snapshot(to: URL(fileURLWithPath: snap), hovering: 1)
                        if ProcessInfo.processInfo.environment["ORBIT_DEMO_EXIT"] != nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Orbit")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: "Orbit — \(Catalog.conversionPathCount) conversions · \(Catalog.tools.count) tools · \(Catalog.actions.count) actions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: hintText(), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        accessibilityItem = NSMenuItem(title: "Checking accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func hintText() -> String {
        "Drag a file, hold \(Preferences.convertKey.symbol) convert · \(Preferences.toolsKey.symbol) tools · \(Preferences.actionsKey.symbol) actions"
    }

    private func refreshAccessibility() {
        let ok = AXIsProcessTrusted()
        accessibilityItem.title = ok ? "✓ Accessibility access granted" : "⚠︎ Grant accessibility access…"
    }

    private func wireWheel() {
        let wheel = WheelController.shared
        monitor.onWheelRequested = { urls, mode, point in wheel.show(files: urls, mode: mode, at: point) }
        monitor.onModeChanged = { mode in wheel.switchMode(mode) }
        monitor.onPointerMoved = { point in wheel.pointerMoved(point) }
        monitor.onMouseReleased = { wheel.hide() }
        wheel.onFlags = { [weak self] flags in self?.monitor.evaluateFlags(flags) }
        wheel.onClosed = { [weak self] in self?.monitor.endSession() }
        wheel.onPerform = { item, files in
            switch item {
            case .conversion(let c): Converter.perform(c, on: files)
            case .tool(let t): Tools.perform(t, on: files)
            case .action(let a): Actions.perform(a, on: files)
            case .more: break
            }
        }
    }

    @objc private func openAccessibility() {
        _ = AccessibilityAccess.isTrusted(prompt: true)
        AccessibilityAccess.openSettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Orbit Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessibility()
        menu.items[1].title = hintText()
    }
}
