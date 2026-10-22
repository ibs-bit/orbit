import AppKit
import CoreText
import UniformTypeIdentifiers

/// Word processing, Markdown, HTML, spreadsheets-as-text, pandoc and LibreOffice bridges.
enum DocumentEngine {

    // MARK: Reading

    static func readAttributed(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let text = try String(contentsOf: url, encoding: .utf8)
            return try markdown(text)
        case "txt", "text":
            let text = try String(contentsOf: url)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "textclipping":
            return NSAttributedString(string: try readTextClipping(url))
        default:
            var attrs: NSDictionary?
            return try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
        }
    }

    static func readTextClipping(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let utiData = plist["UTI-Data"] as? [String: Any] {
            if let s = utiData["public.utf8-plain-text"] as? String { return s }
            if let rtf = utiData["public.rtf"] as? Data, let a = try? NSAttributedString(data: rtf, options: [:], documentAttributes: nil) { return a.string }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        throw OrbitError("Could not read text clipping.")
    }

    /// Markdown → attributed string with real heading sizes.
    static func markdown(_ text: String) throws -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        let parsed = try AttributedString(markdown: text, options: options)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let base = NSFont.systemFont(ofSize: 12)
        result.addAttribute(.font, value: base, range: NSRange(location: 0, length: result.length))
        var paragraphIndex = 0
        for run in parsed.runs {
            let range = NSRange(run.range, in: parsed)
            var font = base
            if let intent = run.presentationIntent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size: CGFloat = [28, 22, 18, 15, 13, 12][min(level, 6) - 1]
                        font = NSFont.boldSystemFont(ofSize: size)
                    case .codeBlock:
                        font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                    default: break
                    }
                }
                let id = intent.components.first?.identity ?? 0
                if id != paragraphIndex, range.location > 0 {
                    paragraphIndex = id
                }
            }
            if let inline = run.inlinePresentationIntent {
                var traits: NSFontTraitMask = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
                if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            }
            result.addAttribute(.font, value: font, range: range)
        }
        // Paragraph breaks: AttributedString(markdown:) separates blocks without newlines.
        let string = result.string
        var insertions: [Int] = []
        var lastIdentity: Int? = nil
        for run in parsed.runs {
            let identity = run.presentationIntent?.components.last?.identity
            let range = NSRange(run.range, in: parsed)
            if let identity, let last = lastIdentity, identity != last, range.location > 0 {
                insertions.append(range.location)
            }
            if identity != nil { lastIdentity = identity }
        }
        for loc in insertions.reversed() where loc <= string.utf16.count {
            result.insert(NSAttributedString(string: "\n\n", attributes: [.font: base]), at: loc)
        }
        return result
    }

    // MARK: Writing

    static func write(_ attributed: NSAttributedString, to url: URL, format: Format) throws {
        let full = NSRange(location: 0, length: attributed.length)
        switch format.id {
        case "txt":
            try attributed.string.write(to: url, atomically: true, encoding: .utf8)
        case "md":
            try naiveMarkdown(attributed).write(to: url, atomically: true, encoding: .utf8)
        case "rtfd":
            let wrapper = try attributed.fileWrapper(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case "pdf":
            try writePDF(attributed, to: url)
        default:
            let type: NSAttributedString.DocumentType
            switch format.id {
            case "rtf": type = .rtf
            case "html": type = .html
            case "docx": type = .officeOpenXML
            case "odt": type = .openDocument
            case "doc": type = .docFormat
            default: throw OrbitError("Can't write \(format.name) natively.")
            }
            let data = try attributed.data(from: full, documentAttributes: [.documentType: type])
            try data.write(to: url)
        }
    }

    /// Minimal Markdown export used when pandoc is not installed.
    static func naiveMarkdown(_ attributed: NSAttributedString) -> String {
        var out = ""
        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            var text = string.substring(with: range)
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if font.pointSize >= 24 { text = text.replacingOccurrences(of: trimmed, with: "# " + trimmed) }
                    else if font.pointSize >= 18 { text = text.replacingOccurrences(of: trimmed, with: "## " + trimmed) }
                    else if font.pointSize >= 14.5 { text = text.replacingOccurrences(of: trimmed, with: "### " + trimmed) }
                    else if traits.contains(.boldFontMask) { text = text.replacingOccurrences(of: trimmed, with: "**" + trimmed + "**") }
                    else if traits.contains(.italicFontMask) { text = text.replacingOccurrences(of: trimmed, with: "_" + trimmed + "_") }
                }
            }
            out += text
        }
        return out
    }

    /// Paginates rich text onto US Letter pages.
    static func writePDF(_ attributed: NSAttributedString, to url: URL, pageSize: CGSize = CGSize(width: 612, height: 792), margin: CGFloat = 54) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw OrbitError("Could not create PDF.") }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: margin, dy: margin)
        var location = 0
        let length = attributed.length
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < length
        ctx.closePDF()
    }

    // MARK: pandoc / LibreOffice

    static func pandoc(_ input: URL, to output: URL, extra: [String] = []) throws {
        guard let exe = Backends.path(for: .pandoc) else { throw MissingBackendError(backend: .pandoc) }
        var args = [input.path, "-o", output.path, "--standalone"] + extra
        if output.pathExtension.lowercased() == "md" { args += ["-t", "gfm", "--wrap=none"] }
        try runProcess(exe, args)
    }

    /// Converts with LibreOffice headless. Returns the produced file (moved to `output`).
    static func soffice(_ input: URL, to ext: String, output: URL, filter: String? = nil) throws {
        guard let exe = Backends.path(for: .soffice) else { throw MissingBackendError(backend: .soffice) }
        let tmp = try OutputPaths.temporaryDirectory()
        let profile = tmp.appendingPathComponent("profile", isDirectory: true)
        let target = filter.map { "\(ext):\($0)" } ?? ext
        try runProcess(exe, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                             "--convert-to", target, "--outdir", tmp.path, input.path])
        let produced = tmp.appendingPathComponent(OutputPaths.baseName(of: input)).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw OrbitError("LibreOffice could not convert \(input.lastPathComponent).")
        }
        try FileManager.default.moveItem(at: produced, to: output)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Document conversion

    static func convertDocument(_ url: URL, to target: Format, backend: Backend) throws -> URL {
        let out = OutputPaths.output(for: url, ext: target.ext)
        switch backend {
        case .soffice: try soffice(url, to: target.ext, output: out)
        case .pandoc: try pandoc(url, to: out)
        default:
            let attributed = try readAttributed(url)
            try write(attributed, to: out, format: target)
        }
        return out
    }

    static func convertPresentation(_ url: URL, to target: Format) throws -> URL {
        if target.kind == .image {
            let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("slides.pdf")
            try soffice(url, to: "pdf", output: tmp)
            return try PDFEngine.pagesToImages(tmp, format: target, baseFor: url)
        }
        let out = OutputPaths.output(for: url, ext: target.ext)
        try soffice(url, to: target.ext, output: out)
        return out
    }

    // MARK: Spreadsheets

    static func convertSpreadsheet(_ url: URL, to target: Format, backend: Backend) throws -> URL {
        let out = OutputPaths.output(for: url, ext: target.ext)
        let textSource = ["csv", "tsv", "tab", "json"].contains(url.pathExtension.lowercased())
        if backend == .soffice, !textSource, ["csv", "tsv", "json", "html"].contains(target.id) {
            // Binary sheet → CSV via LibreOffice, then text transforms.
            let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("sheet.csv")
            try soffice(url, to: "csv", output: tmp, filter: "Text - txt - csv (StarCalc):44,34,76,1")
            let rows = try readRows(tmp)
            try writeRows(rows, to: out, format: target)
            return out
        }
        if backend == .soffice {
            if textSource, target.id == "pdf" || target.id == "xlsx" || target.id == "ods" {
                // LibreOffice needs a CSV it understands; convert TSV/JSON to CSV first.
                let rows = try readRows(url)
                let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("sheet.csv")
                try writeRows(rows, to: tmp, format: Catalog.csv)
                try soffice(tmp, to: target.ext, output: out)
            } else {
                try soffice(url, to: target.ext, output: out)
            }
            return out
        }
        let rows = try readRows(url)
        try writeRows(rows, to: out, format: target)
        return out
    }

    static func readRows(_ url: URL) throws -> [[String]] {
        let text = try String(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "tsv", "tab": return parseDelimited(text, delimiter: "\t")
        case "json": return try rowsFromJSON(text)
        default: return parseDelimited(text, delimiter: ",")
        }
    }

    static func writeRows(_ rows: [[String]], to url: URL, format: Format) throws {
        let text: String
        switch format.id {
        case "tsv": text = rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
        case "json": text = try jsonFromRows(rows)
        case "html": text = htmlTable(rows)
        default: text = rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// RFC 4180 style parser (quoted fields, doubled quotes, embedded newlines).
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    static func rowsFromJSON(_ text: String) throws -> [[String]] {
        guard let data = text.data(using: .utf8) else { return [] }
        let obj = try JSONSerialization.jsonObject(with: data)
        func str(_ v: Any) -> String {
            if let s = v as? String { return s }
            if v is NSNull { return "" }
            if let n = v as? NSNumber { return n.stringValue }
            if let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
            return "\(v)"
        }
        if let arr = obj as? [[String: Any]] {
            var keys: [String] = []
            for o in arr { for k in o.keys where !keys.contains(k) { keys.append(k) } }
            return [keys] + arr.map { o in keys.map { str(o[$0] ?? NSNull()) } }
        }
        if let arr = obj as? [[Any]] { return arr.map { $0.map(str) } }
        throw OrbitError("JSON must be an array of objects or arrays.")
    }

    static func jsonFromRows(_ rows: [[String]]) throws -> String {
        guard let header = rows.first else { return "[]" }
        let objects: [[String: Any]] = rows.dropFirst().map { row in
            var o: [String: Any] = [:]
            for (i, key) in header.enumerated() { o[key.isEmpty ? "column\(i + 1)" : key] = i < row.count ? jsonValue(row[i]) : "" }
            return o
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func jsonValue(_ s: String) -> Any {
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        if s.lowercased() == "true" { return true }
        if s.lowercased() == "false" { return false }
        return s
    }

    static func htmlTable(_ rows: [[String]]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><style>table{border-collapse:collapse;font-family:system-ui}td,th{border:1px solid #ccc;padding:4px 8px}</style></head><body><table>\n"
        for (i, row) in rows.enumerated() {
            let tag = i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return html + "</table></body></html>\n"
    }
}
