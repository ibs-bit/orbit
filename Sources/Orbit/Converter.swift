import Foundation

enum Converter {
    static func perform(_ conversion: Conversion, on urls: [URL]) {
        guard let backend = Backends.firstAvailable(conversion.backends) else {
            let missing = conversion.backends.first ?? .ffmpeg
            let id = HUD.shared.start(title: "Convert to \(conversion.target.name)", subtitle: "")
            HUD.shared.fail(id, message: "\(missing.displayName) is needed for this. Install it with Homebrew.", installCommand: missing.brewCommand)
            return
        }
        let title = conversion.target.id == "folder" ? "Extracting" : "Converting to \(conversion.target.name)"
        let subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        JobRunner.run(title: title, subtitle: subtitle) { job in
            var outputs: [URL] = []
            var failures: [String] = []
            for (i, url) in urls.enumerated() {
                do {
                    outputs.append(try convertOne(url, conversion, backend: backend, job: job.part(i, of: urls.count)))
                } catch let e as MissingBackendError {
                    throw e
                } catch {
                    if urls.count == 1 { throw error }
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if outputs.isEmpty, let first = failures.first { throw OrbitError(first) }
            let message = failures.isEmpty ? nil : "\(outputs.count) done, \(failures.count) failed: \(failures[0])"
            return JobResult(outputs, message: message)
        }
    }

    static func convertOne(_ url: URL, _ conversion: Conversion, backend: Backend, job: Job?) throws -> URL {
        guard let source = Catalog.format(for: url) else { throw OrbitError("Unknown file type.") }
        let target = conversion.target
        switch source.kind {
        case .image:
            return try ImageEngine.convert(url, to: target)
        case .video, .audio:
            return try MediaEngine.convert(url, to: target, backend: backend, job: job)
        case .document:
            return try DocumentEngine.convertDocument(url, to: target, backend: backend)
        case .presentation:
            return try DocumentEngine.convertPresentation(url, to: target)
        case .spreadsheet:
            return try DocumentEngine.convertSpreadsheet(url, to: target, backend: backend)
        case .subtitle:
            return try SubtitleEngine.convert(url, to: target, backend: backend)
        case .archive:
            return try ArchiveEngine.convert(url, to: target)
        case .folder:
            return try ArchiveEngine.create([url], format: target)
        case .pdf:
            return try PDFEngine.convert(url, to: target, backend: backend)
        case .other:
            throw OrbitError("Nothing to convert.")
        }
    }
}
