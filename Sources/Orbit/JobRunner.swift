import AppKit

struct MissingBackendError: LocalizedError {
    let backend: Backend
    var errorDescription: String? { "\(backend.displayName) is not installed." }
}

struct OrbitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Cancelled: Error {}

/// A running unit of work with progress reporting.
final class Job {
    let id: UUID
    private let base: Double
    private let span: Double

    init(id: UUID, base: Double = 0, span: Double = 1) {
        self.id = id; self.base = base; self.span = span
    }

    func progress(_ value: Double) {
        HUD.shared.progress(id, base + min(max(value, 0), 1) * span)
    }

    /// A job reporting progress into slice `index` of `count` equal parts.
    func part(_ index: Int, of count: Int) -> Job {
        guard count > 1 else { return self }
        let s = span / Double(count)
        return Job(id: id, base: base + s * Double(index), span: s)
    }
}

struct JobResult {
    var outputs: [URL]
    var message: String? = nil
    init(_ outputs: [URL], message: String? = nil) { self.outputs = outputs; self.message = message }
    init(_ output: URL) { self.outputs = [output] }
}

enum JobRunner {
    private static let queue = DispatchQueue(label: "orbit.jobs", qos: .userInitiated, attributes: .concurrent)

    static func run(title: String, subtitle: String, work: @escaping (Job) throws -> JobResult) {
        let id = HUD.shared.start(title: title, subtitle: subtitle)
        let job = Job(id: id)
        queue.async {
            do {
                let result = try work(job)
                HUD.shared.succeed(id, outputs: result.outputs, message: result.message)
                DispatchQueue.main.async {
                    if Preferences.playSound { NSSound(named: "Glass")?.play() }
                    if Preferences.revealAfterFinish, !result.outputs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                    }
                }
            } catch is Cancelled {
                HUD.shared.dismiss(id)
            } catch let e as MissingBackendError {
                HUD.shared.fail(id, message: "\(e.backend.displayName) is needed for this. Install it with Homebrew.",
                                installCommand: e.backend.brewCommand)
            } catch {
                HUD.shared.fail(id, message: error.localizedDescription)
                DispatchQueue.main.async { if Preferences.playSound { NSSound(named: "Basso")?.play() } }
            }
        }
    }
}

/// Runs a closure on the main thread and returns its result, whichever thread we are on.
func onMain<T>(_ body: () -> T) -> T {
    if Thread.isMainThread { return body() }
    return DispatchQueue.main.sync(execute: body)
}
