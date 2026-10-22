import AppKit
import Quartz

enum Actions {
    static func perform(_ action: FileAction, on urls: [URL]) {
        switch action.id {
        case "airdrop": airdrop(urls)
        case "float": urls.prefix(6).forEach { FloatWindow.show($0) }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            toast("Copied", urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files ready to paste")
        case "copypath":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            toast("Path copied", urls.count == 1 ? urls[0].path : "\(urls.count) paths")
        case "move": move(urls)
        case "terminal": terminal(urls)
        default: break
        }
    }

    private static func toast(_ title: String, _ subtitle: String) {
        let id = HUD.shared.start(title: title, subtitle: subtitle)
        HUD.shared.succeed(id, outputs: [], message: subtitle)
    }

    private static func airdrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            toast("AirDrop unavailable", "Turn on Wi-Fi and Bluetooth, then try again.")
            return
        }
        service.perform(withItems: urls)
    }

    private static func move(_ urls: [URL]) {
        guard let folder = Dialogs.chooseFolder(title: "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to…") else { return }
        JobRunner.run(title: "Moving", subtitle: "to \(folder.lastPathComponent)") { _ in
            var moved: [URL] = []
            for url in urls {
                let dest = OutputPaths.unique(folder.appendingPathComponent(url.lastPathComponent))
                try FileManager.default.moveItem(at: url, to: dest)
                moved.append(dest)
            }
            return JobResult(moved)
        }
    }

    private static func terminal(_ urls: [URL]) {
        var dirs: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        for dir in dirs.prefix(4) {
            try? runProcess("/usr/bin/open", ["-a", "Terminal", dir.path])
        }
    }
}

/// An always-on-top Quick Look window for a file.
final class FloatWindow: NSPanel {
    private static var open: [FloatWindow] = []

    static func show(_ url: URL) {
        let window = FloatWindow(url: url)
        open.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(url: URL) {
        var size = NSSize(width: 420, height: 320)
        if let px = ImageEngine.pixelSize(url), px.width > 0, px.height > 0 {
            let scale = min(1, 520 / max(px.width, px.height))
            size = NSSize(width: max(160, px.width * scale), height: max(120, px.height * scale))
        }
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = url.lastPathComponent
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        let preview = QLPreviewView(frame: NSRect(origin: .zero, size: size), style: .normal)!
        preview.autostarts = true
        preview.previewItem = url as QLPreviewItem
        preview.autoresizingMask = [.width, .height]
        contentView = preview
        center()
        let offset = CGFloat(FloatWindow.open.count % 6) * 28
        setFrameOrigin(NSPoint(x: frame.origin.x + offset, y: frame.origin.y - offset))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in
            (self?.contentView as? QLPreviewView)?.close()
            FloatWindow.open.removeAll { $0 === self }
        }
    }
}
