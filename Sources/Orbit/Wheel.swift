import AppKit

// MARK: - Items

enum WheelItem {
    case conversion(Conversion)
    case tool(Tool)
    case action(FileAction)
    case more(page: Int, pages: Int)

    var title: String {
        switch self {
        case .conversion(let c): return c.target.id == "folder" ? "Extract" : c.target.name
        case .tool(let t): return t.name
        case .action(let a): return a.name
        case .more: return "More"
        }
    }

    var subtitle: String? {
        switch self {
        case .conversion(let c): return c.target.id == "folder" ? "to folder" : "." + c.target.ext
        case .more(let p, let n): return "\(p + 1) of \(n)"
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .conversion(let c):
            switch c.target.kind {
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "music.note"
            case .document: return "doc.text"
            case .pdf: return "doc.richtext"
            case .presentation: return "rectangle.on.rectangle"
            case .spreadsheet: return "tablecells"
            case .subtitle: return "captions.bubble"
            case .archive: return "archivebox"
            case .folder: return "folder"
            case .other: return "doc"
            }
        case .tool(let t): return t.symbol
        case .action(let a): return a.symbol
        case .more: return "ellipsis.circle"
        }
    }

    var backends: [Backend] {
        switch self {
        case .conversion(let c): return c.backends
        case .tool(let t): return t.backends
        default: return []
        }
    }

    /// The backend that would be used, or nil when every candidate is missing.
    var availableBackend: Backend? {
        backends.isEmpty ? .native : Backends.firstAvailable(backends)
    }

    var missingBackend: Backend? { availableBackend == nil ? backends.first : nil }
    var isAvailable: Bool { availableBackend != nil }
}

// MARK: - Controller

final class WheelController {
    static let shared = WheelController()

    var onPerform: ((WheelItem, [URL]) -> Void)?
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    var onClosed: (() -> Void)?

    private(set) var isVisible = false
    private var panel: WheelPanel?
    private var view: WheelView?
    private var files: [URL] = []
    private var mode: WheelMode = .convert
    private var allItems: [WheelItem] = []
    private var page = 0
    private var moreTimer: Timer?
    private var releaseTimer: Timer?

    private let fullPage = 10
    private let pagedSlots = 9

    private var pageCount: Int {
        allItems.count <= fullPage ? 1 : Int(ceil(Double(allItems.count) / Double(pagedSlots)))
    }

    private var visibleItems: [WheelItem] {
        guard allItems.count > fullPage else { return allItems }
        let start = page * pagedSlots
        let slice = Array(allItems[start..<min(start + pagedSlots, allItems.count)])
        return slice + [.more(page: page, pages: pageCount)]
    }

    func show(files: [URL], mode: WheelMode, at point: NSPoint) {
        self.files = files
        self.mode = mode
        self.page = 0
        self.allItems = items(for: mode)
        let size = WheelView.size
        let panel = self.panel ?? WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size))
        let view = self.view ?? WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        if self.panel == nil {
            panel.contentView = view
            view.controller = self
            self.panel = panel
            self.view = view
        }
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        panel.setFrameOrigin(origin)
        view.configure(files: files, mode: mode, items: visibleItems, pageCount: pageCount)
        view.hovered = nil
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = true
        view.animateIn()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        pointerMoved(point)
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            // Fallback: if the mouse button is up and nothing landed on us, close the wheel.
            guard let self, self.isVisible, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isVisible, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.hide()
            }
        }
    }

    func switchMode(_ mode: WheelMode) {
        guard isVisible, mode != self.mode else { return }
        self.mode = mode
        self.page = 0
        self.allItems = items(for: mode)
        view?.configure(files: files, mode: mode, items: visibleItems, pageCount: pageCount)
        view?.hovered = nil
        pointerMoved(NSEvent.mouseLocation)
    }

    func nextPage() {
        guard pageCount > 1 else { return }
        page = (page + 1) % pageCount
        view?.configure(files: files, mode: mode, items: visibleItems, pageCount: pageCount)
        view?.hovered = nil
        pointerMoved(NSEvent.mouseLocation)
    }

    func pointerMoved(_ screenPoint: NSPoint) {
        guard isVisible, let panel, let view else { return }
        let local = view.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        setHovered(view.hitTest(point: local))
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) { onFlags?(flags) }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        moreTimer?.invalidate(); moreTimer = nil
        releaseTimer?.invalidate(); releaseTimer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isVisible == false { panel.orderOut(nil) }
        })
        onClosed?()
    }

    /// Performs whatever the pointer is over. Returns false if nothing actionable is hovered.
    @discardableResult
    func performHovered() -> Bool {
        guard isVisible, let view, let index = view.hovered, index < visibleItems.count else { hide(); return false }
        let item = visibleItems[index]
        if case .more = item { nextPage(); return true }
        let files = self.files
        hide()
        onPerform?(item, files)
        return true
    }

    /// Renders the current wheel to a PNG (used by the demo mode for screenshots).
    func snapshot(to url: URL, hovering index: Int? = nil) {
        guard let view else { return }
        if let index { view.hovered = index }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: url)
    }

    private func setHovered(_ index: Int?) {
        guard let view else { return }
        guard view.hovered != index else { return }
        view.hovered = index
        moreTimer?.invalidate(); moreTimer = nil
        if let index, index < visibleItems.count, case .more = visibleItems[index] {
            moreTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in self?.nextPage() }
        }
    }

    private func items(for mode: WheelMode) -> [WheelItem] {
        switch mode {
        case .convert: return Catalog.conversions(for: files).map(WheelItem.conversion)
        case .tools: return Catalog.tools(for: files).map(WheelItem.tool)
        case .actions: return Catalog.actions.map(WheelItem.action)
        }
    }
}

// MARK: - Panel

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        acceptsMouseMovedEvents = true
    }
}

// MARK: - View

final class WheelView: NSView {
    static let size: CGFloat = 372

    weak var controller: WheelController?

    private var items: [WheelItem] = []
    private var modeTitle = ""
    private var pageCount = 1
    private var fileIcon: NSImage?
    private var fileLabel = ""

    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private let hubRadius: CGFloat = 50
    private let innerRadius: CGFloat = 58
    private let outerRadius: CGFloat = 170
    private let gapDegrees: CGFloat = 2.2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(files: [URL], mode: WheelMode, items: [WheelItem], pageCount: Int) {
        self.items = items
        self.modeTitle = mode.title
        self.pageCount = pageCount
        if let first = files.first {
            fileIcon = NSWorkspace.shared.icon(forFile: first.path)
            fileLabel = files.count == 1 ? first.lastPathComponent : "\(files.count) items"
        }
        needsDisplay = true
    }

    func animateIn() {
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.82
        anim.toValue = 1
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "appear")
    }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { items.isEmpty ? 360 : 360 / CGFloat(items.count) }

    /// Index of the segment under a point in view coordinates.
    func hitTest(point p: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        guard d >= innerRadius - 6, d <= outerRadius + 16 else { return nil }
        var deg = atan2(dx, dy) * 180 / .pi
        if deg < 0 { deg += 360 }
        let idx = Int(deg / step)
        return min(idx, items.count - 1)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()

        if items.isEmpty {
            drawHub(message: "No \(modeTitle.lowercased()) for this selection")
            ctx.restoreGState()
            return
        }

        for (i, item) in items.enumerated() {
            let isHovered = hovered == i
            let outer = isHovered ? outerRadius + 10 : outerRadius
            let path = segmentPath(index: i, inner: innerRadius, outer: outer)
            let fill: NSColor
            if isHovered {
                fill = item.isAvailable ? NSColor.controlAccentColor : NSColor.systemOrange.withAlphaComponent(0.85)
            } else {
                fill = NSColor(calibratedWhite: 0.13, alpha: 0.94)
            }
            fill.setFill()
            path.fill()
        }
        ctx.restoreGState()

        for (i, item) in items.enumerated() {
            let path = segmentPath(index: i, inner: innerRadius, outer: hovered == i ? outerRadius + 10 : outerRadius)
            NSColor.white.withAlphaComponent(0.09).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawLabel(item, index: i, hovered: hovered == i)
        }
        drawHub(message: nil)
    }

    private func segmentPath(index i: Int, inner: CGFloat, outer: CGFloat) -> NSBezierPath {
        let a0 = CGFloat(i) * step + gapDegrees / 2
        let a1 = CGFloat(i + 1) * step - gapDegrees / 2
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
        path.appendArc(withCenter: center, radius: inner, startAngle: 90 - a1, endAngle: 90 - a0, clockwise: false)
        path.close()
        return path
    }

    private func drawLabel(_ item: WheelItem, index i: Int, hovered: Bool) {
        let mid = (CGFloat(i) + 0.5) * step * .pi / 180
        let r = (innerRadius + outerRadius) / 2 + 6
        let pos = NSPoint(x: center.x + sin(mid) * r, y: center.y + cos(mid) * r)
        let available = item.isAvailable
        let alpha: CGFloat = available ? 1 : 0.45

        if let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium)) {
            let tinted = img.tinted(NSColor.white.withAlphaComponent(alpha))
            let s = NSSize(width: 24, height: 24)
            tinted.draw(in: NSRect(x: pos.x - s.width / 2, y: pos.y + 8, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: para,
        ])
        if let missing = item.missingBackend {
            title.append(NSAttributedString(string: "\nneeds \(missing.displayName)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: para,
            ]))
        } else if let sub = item.subtitle {
            title.append(NSAttributedString(string: "\n" + sub, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.9 : 0.55),
                .paragraphStyle: para,
            ]))
        }
        let rect = NSRect(x: pos.x - 50, y: pos.y - 36, width: 100, height: 42)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawHub(message: String?) {
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))
        NSColor(calibratedWhite: 0.08, alpha: 0.96).setFill()
        hub.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        hub.stroke()

        if let message {
            let para = NSMutableParagraphStyle(); para.alignment = .center
            NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para,
            ]).draw(in: NSRect(x: center.x - 46, y: center.y - 18, width: 92, height: 36))
            return
        }

        if let fileIcon {
            fileIcon.draw(in: NSRect(x: center.x - 16, y: center.y + 2, width: 32, height: 32),
                          from: .zero, operation: .sourceOver, fraction: 1)
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: modeTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]).draw(in: NSRect(x: center.x - 44, y: center.y - 16, width: 88, height: 15))
        NSAttributedString(string: fileLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55), .paragraphStyle: para,
        ]).draw(in: NSRect(x: center.x - 44, y: center.y - 30, width: 88, height: 12))
    }

    // MARK: Pointer + drop handling

    override func mouseMoved(with event: NSEvent) {
        hovered = hitTest(point: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        hovered = hitTest(point: convert(event.locationInWindow, from: nil))
        controller?.performHovered()
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let local = convert(sender.draggingLocation, from: nil)
        controller?.pointerMoved(window?.convertPoint(toScreen: sender.draggingLocation) ?? .zero)
        controller?.flagsChanged(NSEvent.modifierFlags)
        guard let idx = hitTest(point: local), idx < items.count else { return [] }
        return items[idx].isAvailable ? .copy : .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = track(sender)
        return controller?.performHovered() ?? false
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.hide() }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
