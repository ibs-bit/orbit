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
            view.autoresizingMask = [.width, .height]
            panel.effectView.addSubview(view)
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

    let effectView: NSVisualEffectView

    init(contentRect: NSRect) {
        effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentRect.size))
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        acceptsMouseMovedEvents = true
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.autoresizingMask = [.width, .height]
        contentView = effectView
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

    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true; refreshMask() } } }

    private let hubRadius: CGFloat = 50
    private let innerRadius: CGFloat = 58
    private let outerRadius: CGFloat = 170
    private let gapDegrees: CGFloat = 2.6

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
        refreshMask()
    }

    func animateIn() {
        guard let layer = window?.contentView?.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.86
        anim.toValue = 1
        anim.damping = 18
        anim.stiffness = 320
        anim.mass = 0.9
        anim.duration = anim.settlingDuration
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

    // MARK: Glass shape

    /// The visible glass: every segment plus the hub, with the gaps cut out.
    private func shapePath() -> NSBezierPath {
        let path = NSBezierPath()
        for i in items.indices {
            path.append(segmentPath(index: i, inner: innerRadius, outer: hovered == i ? outerRadius + 10 : outerRadius))
        }
        path.append(NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)))
        return path
    }

    /// Masks the blur behind the window to the wheel's shape.
    private func refreshMask() {
        guard let panel = window as? WheelPanel else { return }
        let size = bounds.size
        let path = shapePath()
        let mask = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            path.fill()
            return true
        }
        panel.effectView.maskImage = mask
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMask()
    }

    // MARK: Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSColor.labelColor.withAlphaComponent(isDark ? 0.07 : 0.05)
        let edge = NSColor.labelColor.withAlphaComponent(isDark ? 0.16 : 0.12)
        let gloss = NSColor.white.withAlphaComponent(isDark ? 0.10 : 0.35)

        if items.isEmpty {
            drawHub(message: "No \(modeTitle.lowercased()) for this selection", tile: tile, edge: edge)
            return
        }

        for (i, item) in items.enumerated() {
            let isHovered = hovered == i
            let outer = isHovered ? outerRadius + 10 : outerRadius
            let path = segmentPath(index: i, inner: innerRadius, outer: outer)
            if isHovered {
                let accent = item.isAvailable ? NSColor.controlAccentColor : NSColor.systemOrange
                accent.withAlphaComponent(0.92).setFill()
                path.fill()
                // Soft inner glow on the active tile.
                let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.28), ending: NSColor.white.withAlphaComponent(0))!
                glow.draw(in: path, relativeCenterPosition: NSPoint(x: 0, y: 0.6))
            } else {
                tile.setFill()
                path.fill()
            }
            // Hairline edge + a top-lit highlight that reads as glass.
            path.lineWidth = 1
            edge.setStroke()
            path.stroke()
            drawGloss(index: i, outer: outer, color: gloss)
            drawLabel(item, index: i, hovered: isHovered)
        }
        drawHub(message: nil, tile: tile, edge: edge)
    }

    private func drawGloss(index i: Int, outer: CGFloat, color: NSColor) {
        let a0 = CGFloat(i) * step + gapDegrees / 2
        let a1 = CGFloat(i + 1) * step - gapDegrees / 2
        NSGraphicsContext.saveGraphicsState()
        segmentPath(index: i, inner: innerRadius, outer: outer).addClip()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: outer - 0.75, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
        arc.lineWidth = 1.5
        color.setStroke()
        arc.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private let cornerRadius: CGFloat = 9

    /// An annular sector with all four corners rounded.
    private func segmentPath(index i: Int, inner: CGFloat, outer: CGFloat) -> NSBezierPath {
        let r = min(cornerRadius, (outer - inner) / 2 - 1)
        let a0 = CGFloat(i) * step + gapDegrees / 2
        let a1 = CGFloat(i + 1) * step - gapDegrees / 2
        let ri = inner + r, ro = outer - r
        // Shrink the sector by r on every side, then grow it back with a round-joined stroke.
        let shrinkOuter = asin(min(1, r / ro)) * 180 / .pi
        let shrinkInner = asin(min(1, r / ri)) * 180 / .pi
        let core = CGMutablePath()
        func pt(_ deg: CGFloat, _ rad: CGFloat) -> CGPoint {
            let t = deg * .pi / 180
            return CGPoint(x: center.x + sin(t) * rad, y: center.y + cos(t) * rad)
        }
        let mid = (a0 + a1) / 2
        let o0 = min(a0 + shrinkOuter, mid - 0.01), o1 = max(a1 - shrinkOuter, mid + 0.01)
        let i0 = min(a0 + shrinkInner, mid - 0.01), i1 = max(a1 - shrinkInner, mid + 0.01)
        core.move(to: pt(o0, ro))
        core.addArc(center: center, radius: ro, startAngle: (90 - o0) * .pi / 180, endAngle: (90 - o1) * .pi / 180, clockwise: true)
        core.addLine(to: pt(i1, ri))
        core.addArc(center: center, radius: ri, startAngle: (90 - i1) * .pi / 180, endAngle: (90 - i0) * .pi / 180, clockwise: false)
        core.closeSubpath()
        let grown = core.copy(strokingWithWidth: r * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let rounded = core.union(grown)
        return NSBezierPath(cgPath: rounded)
    }

    private func drawLabel(_ item: WheelItem, index i: Int, hovered: Bool) {
        let mid = (CGFloat(i) + 0.5) * step * .pi / 180
        let r = (innerRadius + outerRadius) / 2 + 6
        let pos = NSPoint(x: center.x + sin(mid) * r, y: center.y + cos(mid) * r)
        let available = item.isAvailable
        let primary: NSColor = hovered ? .white : (available ? .labelColor : .tertiaryLabelColor)
        let secondary: NSColor = hovered ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor

        if let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium)) {
            let tinted = img.tinted(primary)
            let s = NSSize(width: 24, height: 24)
            tinted.draw(in: NSRect(x: pos.x - s.width / 2, y: pos.y + 8, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: primary,
            .paragraphStyle: para,
        ])
        if let missing = item.missingBackend {
            title.append(NSAttributedString(string: "\nneeds \(missing.displayName)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: hovered ? NSColor.white : NSColor.systemOrange,
                .paragraphStyle: para,
            ]))
        } else if let sub = item.subtitle {
            title.append(NSAttributedString(string: "\n" + sub, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: secondary,
                .paragraphStyle: para,
            ]))
        }
        let rect = NSRect(x: pos.x - 50, y: pos.y - 36, width: 100, height: 42)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawHub(message: String?, tile: NSColor, edge: NSColor) {
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))
        tile.setFill()
        hub.fill()
        hub.lineWidth = 1
        edge.setStroke()
        hub.stroke()

        if let message {
            let para = NSMutableParagraphStyle(); para.alignment = .center
            NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
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
            .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
        ]).draw(in: NSRect(x: center.x - 44, y: center.y - 16, width: 88, height: 15))
        NSAttributedString(string: fileLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para,
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
