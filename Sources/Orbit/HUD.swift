import AppKit
import SwiftUI
import Combine

struct Toast: Identifiable {
    enum State {
        case running(Double?)
        case success([URL], String?)
        case failure(String, installCommand: String?)
    }
    let id: UUID
    var title: String
    var subtitle: String
    var state: State
}

final class HUDModel: ObservableObject {
    @Published var toasts: [Toast] = []
}

/// Small floating progress panel in the bottom-right corner of the screen.
final class HUD {
    static let shared = HUD()
    let model = HUDModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = model.$toasts.receive(on: DispatchQueue.main).sink { [weak self] toasts in
            self?.layout(visible: !toasts.isEmpty)
        }
    }

    @discardableResult
    func start(title: String, subtitle: String) -> UUID {
        let id = UUID()
        DispatchQueue.main.async {
            self.model.toasts.append(Toast(id: id, title: title, subtitle: subtitle, state: .running(nil)))
        }
        return id
    }

    func progress(_ id: UUID, _ value: Double) {
        DispatchQueue.main.async { self.update(id) { $0.state = .running(min(max(value, 0), 1)) } }
    }

    func succeed(_ id: UUID, outputs: [URL], message: String? = nil) {
        DispatchQueue.main.async {
            self.update(id) {
                $0.state = .success(outputs, message)
                $0.subtitle = message ?? (outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files")
            }
            self.dismissLater(id, after: 6)
        }
    }

    func fail(_ id: UUID, message: String, installCommand: String? = nil) {
        DispatchQueue.main.async {
            self.update(id) { $0.state = .failure(message, installCommand: installCommand); $0.subtitle = message }
            self.dismissLater(id, after: installCommand == nil ? 10 : 20)
        }
    }

    func dismiss(_ id: UUID) {
        DispatchQueue.main.async { self.model.toasts.removeAll { $0.id == id } }
    }

    private func update(_ id: UUID, _ change: (inout Toast) -> Void) {
        guard let i = model.toasts.firstIndex(where: { $0.id == id }) else { return }
        change(&model.toasts[i])
    }

    private func dismissLater(_ id: UUID, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.dismiss(id) }
    }

    private func layout(visible: Bool) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let h = NSHostingView(rootView: HUDView(model: model))
            p.contentView = h
            panel = p
            hosting = h
        }
        guard let panel, let hosting else { return }
        guard visible else { panel.orderOut(nil); return }
        hosting.rootView = HUDView(model: model)
        let size = hosting.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastRow(toast: toast)
            }
        }
        .padding(10)
        .frame(width: 340)
    }
}

private struct ToastRow: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(toast.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                if case .running(let p?) = toast.state {
                    ProgressView(value: p).progressViewStyle(.linear).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private var icon: some View {
        switch toast.state {
        case .running: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.octagon.fill").font(.system(size: 22)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch toast.state {
        case .success(let urls, _) where !urls.isEmpty:
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                .controlSize(.small)
        case .failure(_, let cmd?):
            Button("Copy install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }.controlSize(.small)
        default:
            Button { HUD.shared.dismiss(toast.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).controlSize(.small)
        }
    }
}
