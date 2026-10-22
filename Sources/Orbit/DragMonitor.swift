import AppKit

/// Watches system-wide mouse drags, detects when Finder (or any app) is dragging files,
/// and reports which wheel the held modifier key asks for.
final class DragMonitor {
    var onWheelRequested: (([URL], WheelMode, NSPoint) -> Void)?
    var onModeChanged: ((WheelMode) -> Void)?
    var onPointerMoved: ((NSPoint) -> Void)?
    var onMouseReleased: (() -> Void)?

    private var monitors: [Any] = []
    private var draggingFiles: [URL] = []
    private var isDraggingFiles = false
    private var wheelOpen = false
    private var currentMode: WheelMode?
    private var pasteboardCountAtMouseDown = -1
    private var lastPasteboardCount = -1

    func start() {
        guard monitors.isEmpty else { return }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] e in self?.dragged(e.modifierFlags) }
        add(.flagsChanged) { [weak self] e in self?.flagsChanged(e.modifierFlags) }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Called by the wheel when the pointer is inside our own window (global monitors don't see those events).
    func evaluateFlags(_ flags: NSEvent.ModifierFlags) {
        guard isDraggingFiles || wheelOpen else { return }
        evaluate(flags)
    }

    /// Resets state after the wheel closes.
    func endSession() {
        wheelOpen = false
        currentMode = nil
        isDraggingFiles = false
        draggingFiles = []
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
            DispatchQueue.main.async { handler(e) }
        }) { monitors.append(m) }
    }

    private func mouseDown() {
        pasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        isDraggingFiles = false
        draggingFiles = []
    }

    private func dragged(_ flags: NSEvent.ModifierFlags) {
        if !isDraggingFiles {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != pasteboardCountAtMouseDown, pb.changeCount != lastPasteboardCount else { return }
            guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return }
            lastPasteboardCount = pb.changeCount
            isDraggingFiles = true
            draggingFiles = urls
        }
        evaluate(flags)
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard isDraggingFiles else { return }
        evaluate(flags)
    }

    private func evaluate(_ flags: NSEvent.ModifierFlags) {
        let location = NSEvent.mouseLocation
        let requested = Preferences.mode(for: flags)
        if !wheelOpen {
            guard let mode = requested else { return }
            wheelOpen = true
            currentMode = mode
            onWheelRequested?(draggingFiles, mode, location)
        } else {
            if let mode = requested, mode != currentMode {
                currentMode = mode
                onModeChanged?(mode)
            }
            onPointerMoved?(location)
        }
    }

    private func mouseUp() {
        let wasOpen = wheelOpen
        isDraggingFiles = false
        if wasOpen {
            // Give a drop inside our own panel a moment to land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.wheelOpen else { return }
                self.onMouseReleased?()
            }
        }
    }
}
