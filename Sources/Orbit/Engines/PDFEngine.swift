import AppKit
import PDFKit
import Vision

enum PDFEngine {

    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw OrbitError("Could not open \(url.lastPathComponent).") }
        if doc.isLocked {
            if let password, doc.unlock(withPassword: password) { return doc }
            throw OrbitError("\(url.lastPathComponent) is password protected. Use Remove password first.")
        }
        return doc
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        var bounds = page.bounds(for: .cropBox)
        if page.rotation % 180 != 0 { bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) }
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = ImageEngine.context(width: w, height: h) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Writes every page as an image. Single page → one file; multiple → a folder.
    static func pagesToImages(_ url: URL, format: Format, baseFor: URL? = nil) throws -> URL {
        let doc = try open(url)
        let base = baseFor ?? url
        if doc.pageCount == 1, let page = doc.page(at: 0), let img = render(page) {
            let out = OutputPaths.output(for: base, ext: format.ext)
            try ImageEngine.write(img, to: out, format: format)
            return out
        }
        let folder = OutputPaths.output(for: base, ext: "", suffix: "pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = OutputPaths.baseName(of: base)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = render(page) else { continue }
            try ImageEngine.write(img, to: folder.appendingPathComponent("\(name)-\(i + 1).\(format.ext)"), format: format)
        }
        return folder
    }

    static func text(_ url: URL, ocrIfEmpty: Bool = true) throws -> String {
        let doc = try open(url)
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var s = page.string ?? ""
            if ocrIfEmpty, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let img = render(page) {
                s = (try? recognizeText(img)) ?? ""
            }
            parts.append(s)
        }
        return parts.joined(separator: "\n\n")
    }

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func convert(_ url: URL, to target: Format, backend: Backend) throws -> URL {
        switch target.kind {
        case .image:
            if ImageEngine.canEncode(target) { return try pagesToImages(url, format: target) }
            let pngs = try pagesToImages(url, format: Catalog.png)
            // Convert the produced PNG(s) with ffmpeg.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: pngs.path, isDirectory: &isDir)
            if isDir.boolValue {
                for item in try FileManager.default.contentsOfDirectory(at: pngs, includingPropertiesForKeys: nil) where item.pathExtension == "png" {
                    _ = try ImageEngine.convert(item, to: target)
                    try FileManager.default.removeItem(at: item)
                }
                return pngs
            }
            let out = try ImageEngine.convert(pngs, to: target)
            try FileManager.default.removeItem(at: pngs)
            return out
        default: break
        }
        let out = OutputPaths.output(for: url, ext: target.ext)
        switch (target.id, backend) {
        case ("txt", _):
            try text(url).write(to: out, atomically: true, encoding: .utf8)
        case ("html", .native):
            let body = text(url: url)
            try ("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(OutputPaths.baseName(of: url))</title></head><body>\n"
                 + body + "\n</body></html>\n").write(to: out, atomically: true, encoding: .utf8)
        case ("rtf", _):
            let attributed = NSAttributedString(string: try text(url), attributes: [.font: NSFont.systemFont(ofSize: 12)])
            try DocumentEngine.write(attributed, to: out, format: Catalog.rtf)
        case (_, .soffice):
            let filter: String? = target.id == "docx" ? "writer_pdf_import" : (target.id == "pptx" ? "impress_pdf_import" : nil)
            try sofficeImport(url, to: target.ext, output: out, importFilter: filter)
        case (_, .pandoc):
            let html = try OutputPaths.temporaryDirectory().appendingPathComponent("doc.html")
            try ("<html><body>" + text(url: url) + "</body></html>").write(to: html, atomically: true, encoding: .utf8)
            try DocumentEngine.pandoc(html, to: out)
        default:
            throw OrbitError("Can't convert PDF to \(target.name).")
        }
        return out
    }

    private static func text(url: URL) -> String {
        let raw = (try? text(url)) ?? ""
        return raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return escaped.isEmpty ? "" : "<p>\(escaped)</p>"
        }.joined(separator: "\n")
    }

    private static func sofficeImport(_ input: URL, to ext: String, output: URL, importFilter: String?) throws {
        guard let exe = Backends.path(for: .soffice) else { throw MissingBackendError(backend: .soffice) }
        let tmp = try OutputPaths.temporaryDirectory()
        let profile = tmp.appendingPathComponent("profile", isDirectory: true)
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore"]
        if let importFilter { args.append("--infilter=\(importFilter)") }
        args += ["--convert-to", ext, "--outdir", tmp.path, input.path]
        try runProcess(exe, args)
        let produced = tmp.appendingPathComponent(OutputPaths.baseName(of: input)).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: produced.path) else { throw OrbitError("LibreOffice could not convert the PDF.") }
        try FileManager.default.moveItem(at: produced, to: output)
    }

    // MARK: Tools

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { merged.insert(p, at: merged.pageCount) } }
        }
        let out = OutputPaths.unique(OutputPaths.directory(for: urls[0]).appendingPathComponent("Merged.pdf"))
        guard merged.write(to: out) else { throw OrbitError("Could not write merged PDF.") }
        return out
    }

    static func split(_ url: URL) throws -> URL {
        let doc = try open(url)
        let folder = OutputPaths.output(for: url, ext: "", suffix: "pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = OutputPaths.baseName(of: url)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent("\(name)-\(i + 1).pdf"))
        }
        return folder
    }

    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "compressed")
        let options: [PDFDocumentWriteOption: Any] = [.optimizeImagesForScreenOption: true, .saveImagesAsJPEGOption: true]
        guard doc.write(to: out, withOptions: options) else { throw OrbitError("Could not write compressed PDF.") }
        if ImageEngine.fileSize(out) >= ImageEngine.fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw OrbitError("\(url.lastPathComponent) is already as small as it gets.")
        }
        return out
    }

    static func rotate(_ url: URL, degrees: Int = 90) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += degrees }
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "rotated")
        guard doc.write(to: out) else { throw OrbitError("Could not write rotated PDF.") }
        return out
    }

    static func ocr(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "searchable")
        guard doc.write(to: out, withOptions: [.saveTextFromOCROption: true]) else { throw OrbitError("OCR failed.") }
        return out
    }

    static func lock(_ url: URL, password: String) throws -> URL {
        let doc = try open(url)
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "locked")
        guard doc.write(to: out, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
            throw OrbitError("Could not write locked PDF.")
        }
        return out
    }

    static func unlock(_ url: URL, password: String) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw OrbitError("Could not open PDF.") }
        if doc.isLocked, !doc.unlock(withPassword: password) { throw OrbitError("Wrong password.") }
        // Re-saving keeps the encryption, so rebuild the document page by page.
        let copy = PDFDocument()
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { copy.insert(p, at: copy.pageCount) } }
        copy.documentAttributes = doc.documentAttributes
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "unlocked")
        guard copy.write(to: out) else { throw OrbitError("Could not write unlocked PDF.") }
        return out
    }

    static func setMetadata(_ url: URL, title: String, author: String, subject: String, keywords: String) throws -> URL {
        let doc = try open(url)
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.titleAttribute] = title
        attrs[PDFDocumentAttribute.authorAttribute] = author
        attrs[PDFDocumentAttribute.subjectAttribute] = subject
        attrs[PDFDocumentAttribute.keywordsAttribute] = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        doc.documentAttributes = attrs
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "tagged")
        guard doc.write(to: out) else { throw OrbitError("Could not write PDF.") }
        return out
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = OutputPaths.output(for: url, ext: "pdf", suffix: "clean")
        guard doc.write(to: out) else { throw OrbitError("Could not write PDF.") }
        return out
    }

    static func currentMetadata(_ url: URL) -> [String] {
        let attrs = (try? open(url))?.documentAttributes ?? [:]
        let keywords = (attrs[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ") ?? ""
        return [attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "",
                attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "",
                attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? "",
                keywords]
    }
}
