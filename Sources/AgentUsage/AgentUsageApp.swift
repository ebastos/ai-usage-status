import AgentUsageCore
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            DashboardView(showsDismiss: true)
                .environmentObject(store)
        } label: {
            MenuLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        .commands {
            CommandMenu("Usage") {
                Button("Refresh") { store.refresh(force: true) }
                    .keyboardShortcut("r", modifiers: [])
            }
        }
    }
}

struct MenuLabel: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage("showMenuBarText") private var showText = true
    @AppStorage("enabledProviders") private var enabledRaw = ProviderID.all.joined(separator: ",")
    @AppStorage("providerOrder") private var orderRaw = ProviderID.all.joined(separator: ",")

    var body: some View {
        let enabled = ProviderList.enabled(order: ProviderList.normalizedOrder(orderRaw), enabledRaw: enabledRaw)
        let text = store.menuText(enabled: enabled)
        if showText, !text.isEmpty {
            Text(text)
        } else if showText {
            Text("Usage")
        } else {
            Image(systemName: "chart.bar.fill")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageStore.shared.start()
        if let path = Self.argument(after: "--snapshot") {
            Task { @MainActor in
                let store = UsageStore.shared
                let deadline = Date().addingTimeInterval(25)
                while Date() < deadline {
                    let ready = store.snapshots.filter { $0.status == .ready }.count
                    if ready >= 3 { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                Self.renderSnapshot(store: store, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return
        }
        guard CommandLine.arguments.contains("--window") else { return }
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingController(
            rootView: DashboardView(showsDismiss: false).environmentObject(UsageStore.shared)
        )
        // Default sizing options resize the window to SwiftUI's ideal height and can push it off a display.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Agent Usage"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 440, height: 420)
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.backgroundColor = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.17, alpha: 1)
        window.setContentSize(NSSize(width: 600, height: 780))
        place(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.place(window)
        }
    }

    /// Keeps the panel fully on the display under the pointer, including displays left of the menu bar.
    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if frame.width < 560 { frame.size.width = 600 }
        if frame.height < 640 { frame.size.height = min(780, visible.height - 24) }
        frame.size.width = min(frame.width, visible.width - 24)
        frame.size.height = min(frame.height, visible.height - 24)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        if frame.minX < visible.minX { frame.origin.x = visible.minX + 12 }
        if frame.minY < visible.minY { frame.origin.y = visible.minY + 12 }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width - 12 }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height - 12 }
        window.setFrame(frame, display: true)
    }

    /// `--snapshot path.png 500 1000` renders the resizable window layout at that size.
    private static func snapshotCanvas() -> CGSize? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"),
              args.indices.contains(index + 3),
              let width = Double(args[index + 2]),
              let height = Double(args[index + 3]),
              width > 100, height > 100 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func renderSnapshot(store: UsageStore, to url: URL) {
        let canvas = snapshotCanvas()
        let width = canvas?.width ?? 600
        let height = canvas?.height ?? 1680
        let fills = canvas != nil
        let host = NSHostingView(
            rootView: DashboardView(showsDismiss: false, scrollLimit: fills ? nil : 1500)
                .environmentObject(store)
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            var frame = window.frame
            frame.origin = NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY - frame.height - 40
            )
            window.setFrame(frame, display: true)
        }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            fputs("snapshot failed\n", stderr)
            return
        }
        host.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot failed\n", stderr)
            return
        }
        try? data.write(to: url)
        let names = store.snapshots.map(\.name).joined(separator: ",")
        fputs("snapshot providers \(names)\n", stderr)
        window.orderOut(nil)
    }
}
