import AppKit
import CryptoKit
import AVFoundation

enum Tools {
    static func perform(_ tool: Tool, on urls: [URL]) {
        guard let backend = Backends.firstAvailable(tool.backends) else {
            let missing = tool.backends.first ?? .ffmpeg
            let id = HUD.shared.start(title: tool.name, subtitle: "")
            HUD.shared.fail(id, message: "\(missing.displayName) is needed for this. Install it with Homebrew.", installCommand: missing.brewCommand)
            return
        }
        // Gather parameters on the main thread before the job starts.
        guard let params = parameters(for: tool, urls: urls) else { return }
        let subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        JobRunner.run(title: tool.name.replacingOccurrences(of: "…", with: ""), subtitle: subtitle) { job in
            if tool.multiFile { return try runMulti(tool, urls: urls, backend: backend, params: params, job: job) }
            var outputs: [URL] = []
            var message: String?
            var failures: [String] = []
            for (i, url) in urls.enumerated() {
                do {
                    let r = try runSingle(tool, url: url, backend: backend, params: params, job: job.part(i, of: urls.count))
                    outputs += r.outputs
                    if let m = r.message { message = m }
                } catch let e as MissingBackendError { throw e }
                catch {
                    if urls.count == 1 { throw error }
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if outputs.isEmpty, message == nil, let f = failures.first { throw OrbitError(f) }
            if !failures.isEmpty { message = "\(outputs.count) done, \(failures.count) failed: \(failures[0])" }
            return JobResult(outputs, message: message)
        }
    }

    // MARK: Parameters

    private static func parameters(for tool: Tool, urls: [URL]) -> [String]? {
        switch tool.id {
        case "image.crop":
            let options = ["Square 1:1", "Landscape 16:9", "Landscape 4:3", "Landscape 3:2", "Portrait 9:16", "Portrait 4:5"]
            guard let i = Dialogs.choice(title: "Crop", message: "Crop the center of the image to:", options: options) else { return nil }
            return [String(i)]
        case "image.resize":
            let size = ImageEngine.pixelSize(urls[0]) ?? .zero
            return Dialogs.form(title: "Resize", message: "Enter a width and/or height in pixels, or a percentage like 50%.",
                                fields: [.init(label: "Width", value: "\(Int(size.width))"), .init(label: "Height", value: "")])
        case "video.trim", "audio.trim":
            let d = MediaEngine.duration(of: urls[0])
            guard let (s, e) = Dialogs.trimRange(duration: d) else { return nil }
            return [String(s), String(e)]
        case "pdf.lock":
            guard let pw = Dialogs.password(title: "Lock PDF", message: "Choose a password for the new copy."), !pw.isEmpty else { return nil }
            return [pw]
        case "pdf.unlock":
            guard let pw = Dialogs.password(title: "Remove password", message: "Enter the PDF's current password.") else { return nil }
            return [pw]
        case "pdf.metadata":
            let current = PDFEngine.currentMetadata(urls[0])
            return Dialogs.form(title: "PDF metadata", message: "Saved to a new copy.", fields: [
                .init(label: "Title", value: current[0]), .init(label: "Author", value: current[1]),
                .init(label: "Subject", value: current[2]), .init(label: "Keywords", value: current[3]),
            ])
        case "audio.metadata":
            return Dialogs.form(title: "Audio tags", message: "Saved to a new copy.", fields: [
                .init(label: "Title", value: OutputPaths.baseName(of: urls[0])), .init(label: "Artist", value: ""),
                .init(label: "Album", value: ""), .init(label: "Year", value: ""),
            ])
        default:
            return []
        }
    }

    // MARK: Single-file tools

    private static func runSingle(_ tool: Tool, url: URL, backend: Backend, params: [String], job: Job) throws -> JobResult {
        switch tool.id {
        // Images
        case "image.compress":
            return JobResult(try ImageEngine.compressed(url))
        case "image.crop":
            let aspects: [CGFloat] = [1, 16.0 / 9, 4.0 / 3, 3.0 / 2, 9.0 / 16, 4.0 / 5]
            let aspect = aspects[min(Int(params[0]) ?? 0, aspects.count - 1)]
            return JobResult(try writeEdited(ImageEngine.cropped(try ImageEngine.load(url), aspect: aspect), from: url, suffix: "cropped"))
        case "image.resize":
            let image = try ImageEngine.load(url)
            let size = try resizeTarget(params, width: image.width, height: image.height)
            return JobResult(try writeEdited(ImageEngine.scaled(image, to: size), from: url, suffix: "\(Int(size.width))x\(Int(size.height))"))
        case "image.rotate":
            return JobResult(try writeEdited(ImageEngine.rotated90(try ImageEngine.load(url)), from: url, suffix: "rotated"))
        case "image.flip":
            return JobResult(try writeEdited(ImageEngine.flippedHorizontally(try ImageEngine.load(url)), from: url, suffix: "flipped"))
        case "image.grayscale":
            return JobResult(try writeEdited(ImageEngine.grayscale(try ImageEngine.load(url)), from: url, suffix: "gray"))
        case "image.removebg":
            let out = OutputPaths.output(for: url, ext: "png", suffix: "nobg")
            try ImageEngine.write(try ImageEngine.removeBackground(try ImageEngine.load(url)), to: out, format: Catalog.png)
            return JobResult(out)
        case "image.icon":
            let out = OutputPaths.output(for: url, ext: "icns")
            try ImageEngine.writeICNS(try ImageEngine.load(url), to: out)
            return JobResult(out)

        // Video
        case "video.compress":
            let out = OutputPaths.output(for: url, ext: "mp4", suffix: "compressed")
            try MediaEngine.ffmpeg(input: url, args: ["-c:v", "libx264", "-preset", "faster", "-crf", "28", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"], output: out, job: job)
            return JobResult(out)
        case "video.trim", "audio.trim":
            let start = Double(params[0]) ?? 0, end = Double(params[1]) ?? 0
            let ext = tool.id == "video.trim" ? (backend == .native ? "mp4" : url.pathExtension) : (backend == .native ? "m4a" : url.pathExtension)
            let out = OutputPaths.output(for: url, ext: ext, suffix: "trimmed")
            if backend == .native {
                let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
                try MediaEngine.export(url, to: out, fileType: tool.id == "video.trim" ? .mp4 : .m4a,
                                       preset: tool.id == "video.trim" ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A,
                                       job: job, timeRange: range)
            } else {
                try MediaEngine.ffmpeg(input: url, args: ["-t", String(end - start), "-c", "copy"], output: out, job: job, inputArgs: ["-ss", String(start)])
            }
            return JobResult(out)
        case "video.split", "audio.split":
            let d = MediaEngine.duration(of: url)
            guard d > 0.2 else { throw OrbitError("Could not read duration.") }
            let half = d / 2
            let a = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "part1")
            let b = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "part2")
            try MediaEngine.ffmpeg(input: url, args: ["-t", String(half), "-c", "copy"], output: a, job: job.part(0, of: 2))
            try MediaEngine.ffmpeg(input: url, args: ["-c", "copy"], output: b, job: job.part(1, of: 2), inputArgs: ["-ss", String(half)])
            return JobResult([a, b])
        case "video.audio":
            let out = OutputPaths.output(for: url, ext: "m4a")
            if backend == .native {
                try MediaEngine.export(url, to: out, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, job: job)
            } else {
                try MediaEngine.ffmpeg(input: url, args: ["-vn", "-c:a", "aac", "-b:a", "192k"], output: out, job: job)
            }
            return JobResult(out)
        case "video.mute":
            let out = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "muted")
            try MediaEngine.ffmpeg(input: url, args: ["-an", "-c:v", "copy"], output: out, job: job)
            return JobResult(out)
        case "video.frame":
            let out = OutputPaths.output(for: url, ext: "png", suffix: "frame")
            try ImageEngine.write(try MediaEngine.thumbnail(url), to: out, format: Catalog.png)
            return JobResult(out)
        case "video.speed":
            let out = OutputPaths.output(for: url, ext: "mp4", suffix: "2x")
            try MediaEngine.ffmpeg(input: url, args: ["-filter:v", "setpts=0.5*PTS", "-filter:a", "atempo=2.0", "-c:v", "libx264", "-preset", "faster", "-crf", "22", "-pix_fmt", "yuv420p", "-c:a", "aac"], output: out, job: job)
            return JobResult(out)
        case "video.rotate":
            let out = OutputPaths.output(for: url, ext: "mp4", suffix: "rotated")
            try MediaEngine.ffmpeg(input: url, args: ["-vf", "transpose=1", "-c:v", "libx264", "-preset", "faster", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "copy"], output: out, job: job)
            return JobResult(out)

        // Audio
        case "audio.compress":
            let out = OutputPaths.output(for: url, ext: "m4a", suffix: "compressed")
            if backend == .native {
                try MediaEngine.afconvert(url, to: out, target: Catalog.m4a, bitrate: 96_000)
            } else {
                try MediaEngine.ffmpeg(input: url, args: ["-vn", "-c:a", "aac", "-b:a", "96k"], output: out, job: job)
            }
            return JobResult(out)
        case "audio.normalize":
            let out = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "normalized")
            try MediaEngine.ffmpeg(input: url, args: ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"], output: out, job: job)
            return JobResult(out)
        case "audio.mono":
            let out = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "mono")
            try MediaEngine.ffmpeg(input: url, args: ["-ac", "1"], output: out, job: job)
            return JobResult(out)
        case "audio.metadata":
            let out = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "tagged")
            var args = ["-c", "copy"]
            for (key, value) in zip(["title", "artist", "album", "date"], params) where !value.isEmpty { args += ["-metadata", "\(key)=\(value)"] }
            try MediaEngine.ffmpeg(input: url, args: args, output: out, job: job)
            return JobResult(out)

        // PDF
        case "pdf.compress": return JobResult(try PDFEngine.compress(url))
        case "pdf.split": return JobResult(try PDFEngine.split(url))
        case "pdf.rotate": return JobResult(try PDFEngine.rotate(url))
        case "pdf.text":
            let out = OutputPaths.output(for: url, ext: "txt")
            try PDFEngine.text(url).write(to: out, atomically: true, encoding: .utf8)
            return JobResult(out)
        case "pdf.ocr": return JobResult(try PDFEngine.ocr(url))
        case "pdf.lock": return JobResult(try PDFEngine.lock(url, password: params[0]))
        case "pdf.unlock": return JobResult(try PDFEngine.unlock(url, password: params[0]))
        case "pdf.metadata":
            return JobResult(try PDFEngine.setMetadata(url, title: params[0], author: params[1], subject: params[2], keywords: params[3]))

        // Any
        case "any.stripmeta":
            switch Catalog.kind(for: url) {
            case .image:
                let format = Catalog.format(for: url).flatMap { ImageEngine.canEncode($0) ? $0 : nil } ?? Catalog.png
                let out = OutputPaths.output(for: url, ext: format.ext, suffix: "clean")
                try ImageEngine.write(try ImageEngine.load(url), to: out, format: format, quality: 0.95)
                return JobResult(out)
            case .pdf:
                return JobResult(try PDFEngine.stripMetadata(url))
            default:
                let out = OutputPaths.output(for: url, ext: url.pathExtension, suffix: "clean")
                try MediaEngine.ffmpeg(input: url, args: ["-map_metadata", "-1", "-c", "copy"], output: out, job: job)
                return JobResult(out)
            }
        case "any.zip":
            return JobResult(try ArchiveEngine.create([url], format: Catalog.zip))
        case "any.checksum":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            onMain {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
            }
            return JobResult([], message: "SHA-256 copied: \(hex.prefix(16))…")
        default:
            throw OrbitError("Unknown tool \(tool.id).")
        }
    }

    // MARK: Multi-file tools

    private static func runMulti(_ tool: Tool, urls: [URL], backend: Backend, params: [String], job: Job) throws -> JobResult {
        switch tool.id {
        case "image.merge":
            let images = try urls.map { try ImageEngine.load($0) }
            let out = OutputPaths.unique(OutputPaths.directory(for: urls[0]).appendingPathComponent("Combined.pdf"))
            try ImageEngine.writePDF(images, to: out)
            return JobResult(out)
        case "pdf.merge":
            return JobResult(try PDFEngine.merge(urls))
        case "video.merge", "audio.merge":
            // Link each input under a generated name so the concat list never carries user-controlled text.
            let tmp = try OutputPaths.temporaryDirectory()
            var lines: [String] = []
            for (i, url) in urls.enumerated() {
                let name = "input\(i).\(url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber })"
                try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent(name), withDestinationURL: url)
                lines.append("file '\(name)'")
            }
            let list = tmp.appendingPathComponent("list.txt")
            try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            let ext = tool.id == "video.merge" ? "mp4" : "m4a"
            let out = OutputPaths.unique(OutputPaths.directory(for: urls[0]).appendingPathComponent("Joined." + ext))
            let args = tool.id == "video.merge"
                ? ["-c:v", "libx264", "-preset", "faster", "-crf", "22", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
                : ["-vn", "-c:a", "aac", "-b:a", "192k"]
            try MediaEngine.ffmpeg(input: list, args: args, output: out, job: nil, inputArgs: ["-f", "concat"])
            return JobResult(out)
        default:
            throw OrbitError("Unknown tool \(tool.id).")
        }
    }

    // MARK: Helpers

    /// Writes an edited image in the source format when that format is encodable, else PNG.
    private static func writeEdited(_ image: CGImage, from url: URL, suffix: String) throws -> URL {
        var format = Catalog.format(for: url) ?? Catalog.png
        if !ImageEngine.canEncode(format) || ["ico", "icns", "pdf", "gif"].contains(format.id) { format = image.hasAlpha ? Catalog.png : Catalog.jpg }
        let out = OutputPaths.output(for: url, ext: format.ext, suffix: suffix)
        try ImageEngine.write(image, to: out, format: format)
        return out
    }

    private static func resizeTarget(_ params: [String], width: Int, height: Int) throws -> CGSize {
        let w = params.count > 0 ? params[0].trimmingCharacters(in: .whitespaces) : ""
        let h = params.count > 1 ? params[1].trimmingCharacters(in: .whitespaces) : ""
        let aspect = CGFloat(width) / CGFloat(height)
        if w.hasSuffix("%"), let pct = Double(w.dropLast()) {
            let f = CGFloat(pct / 100)
            return CGSize(width: (CGFloat(width) * f).rounded(), height: (CGFloat(height) * f).rounded())
        }
        let tw = Double(w), th = Double(h)
        switch (tw, th) {
        case let (tw?, th?): return CGSize(width: tw, height: th)
        case let (tw?, nil): return CGSize(width: tw, height: (CGFloat(tw) / aspect).rounded())
        case let (nil, th?): return CGSize(width: (CGFloat(th) * aspect).rounded(), height: th)
        default: throw OrbitError("Enter a width, a height, or a percentage.")
        }
    }
}
