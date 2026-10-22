import Foundation
import AppKit

// MARK: - Kinds, backends, formats

enum FileKind: String, CaseIterable {
    case image, video, audio, document, presentation, spreadsheet, subtitle, archive, pdf, folder, other

    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .presentation: return "Slides"
        case .spreadsheet: return "Spreadsheet"
        case .subtitle: return "Subtitles"
        case .archive: return "Archive"
        case .pdf: return "PDF"
        case .folder: return "Folder"
        case .other: return "File"
        }
    }
}

enum Backend: String, CaseIterable {
    case native, ffmpeg, pandoc, soffice, sevenZip, cwebp

    var displayName: String {
        switch self {
        case .native: return "Built in"
        case .cwebp: return "libwebp"
        case .ffmpeg: return "ffmpeg"
        case .pandoc: return "pandoc"
        case .soffice: return "LibreOffice"
        case .sevenZip: return "7-Zip"
        }
    }

    var brewCommand: String? {
        switch self {
        case .native: return nil
        case .ffmpeg: return "brew install ffmpeg"
        case .pandoc: return "brew install pandoc"
        case .soffice: return "brew install --cask libreoffice"
        case .sevenZip: return "brew install sevenzip"
        case .cwebp: return "brew install webp"
        }
    }
}

struct Format: Hashable, Identifiable {
    let id: String          // canonical extension, e.g. "jpg"
    let name: String        // display name, e.g. "JPEG"
    let exts: [String]      // every extension that maps to this format
    let kind: FileKind
    let utType: String?     // ImageIO / UTType identifier when relevant

    init(_ id: String, _ name: String, _ exts: [String] = [], kind: FileKind, utType: String? = nil) {
        self.id = id
        self.name = name
        self.exts = exts.isEmpty ? [id] : exts
        self.kind = kind
        self.utType = utType
    }

    /// Extension used for files written in this format.
    var ext: String { exts[0] }
}

struct Conversion: Identifiable, Hashable {
    let target: Format
    /// Backends able to perform this conversion, best first.
    let backends: [Backend]
    var id: String { target.id }

    static func == (a: Conversion, b: Conversion) -> Bool { a.target == b.target }
    func hash(into h: inout Hasher) { h.combine(target) }
}

struct Tool: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    /// Kinds the tool applies to; empty means any file.
    let kinds: Set<FileKind>
    let backends: [Backend]
    /// Requires two or more files (merge style tools).
    let multiFile: Bool

    init(_ id: String, _ name: String, symbol: String, kinds: Set<FileKind>, backends: [Backend] = [.native], multiFile: Bool = false) {
        self.id = id; self.name = name; self.symbol = symbol; self.kinds = kinds; self.backends = backends; self.multiFile = multiFile
    }

    static func == (a: Tool, b: Tool) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct FileAction: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
}

// MARK: - Catalog

enum Catalog {

    // Image formats
    static let png  = Format("png", "PNG", kind: .image, utType: "public.png")
    static let jpg  = Format("jpg", "JPEG", ["jpg", "jpeg", "jpe"], kind: .image, utType: "public.jpeg")
    static let heic = Format("heic", "HEIC", ["heic", "heif", "hif"], kind: .image, utType: "public.heic")
    static let tiff = Format("tiff", "TIFF", ["tiff", "tif"], kind: .image, utType: "public.tiff")
    static let gif  = Format("gif", "GIF", kind: .image, utType: "com.compuserve.gif")
    static let bmp  = Format("bmp", "BMP", kind: .image, utType: "com.microsoft.bmp")
    static let webp = Format("webp", "WebP", kind: .image, utType: "org.webmproject.webp")
    static let avif = Format("avif", "AVIF", kind: .image, utType: "public.avif")
    static let jp2  = Format("jp2", "JPEG 2000", ["jp2", "j2k", "jpx"], kind: .image, utType: "public.jpeg-2000")
    static let ico  = Format("ico", "ICO", kind: .image, utType: "com.microsoft.ico")
    static let icns = Format("icns", "ICNS", kind: .image, utType: "com.apple.icns")
    static let psd  = Format("psd", "Photoshop", kind: .image, utType: "com.adobe.photoshop-image")
    static let svg  = Format("svg", "SVG", kind: .image, utType: "public.svg-image")
    static let tga  = Format("tga", "TGA", kind: .image, utType: "com.truevision.tga-image")
    static let raw  = Format("raw", "RAW", ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"], kind: .image)

    // Video formats
    static let mp4  = Format("mp4", "MP4", kind: .video)
    static let mov  = Format("mov", "QuickTime", ["mov", "qt"], kind: .video)
    static let m4v  = Format("m4v", "M4V", kind: .video)
    static let mkv  = Format("mkv", "MKV", kind: .video)
    static let avi  = Format("avi", "AVI", kind: .video)
    static let webm = Format("webm", "WebM", kind: .video)
    static let wmv  = Format("wmv", "WMV", kind: .video)
    static let flv  = Format("flv", "FLV", kind: .video)
    static let mpg  = Format("mpg", "MPEG", ["mpg", "mpeg"], kind: .video)
    static let gp3  = Format("3gp", "3GP", ["3gp", "3g2"], kind: .video)
    static let ts   = Format("ts", "MPEG-TS", ["ts", "mts", "m2ts"], kind: .video)
    static let ogv  = Format("ogv", "Ogg Video", kind: .video)

    // Audio formats
    static let mp3  = Format("mp3", "MP3", kind: .audio)
    static let m4a  = Format("m4a", "M4A", kind: .audio)
    static let wav  = Format("wav", "WAV", kind: .audio)
    static let aiff = Format("aiff", "AIFF", ["aiff", "aif"], kind: .audio)
    static let flac = Format("flac", "FLAC", kind: .audio)
    static let ogg  = Format("ogg", "Ogg Vorbis", ["ogg", "oga"], kind: .audio)
    static let opus = Format("opus", "Opus", kind: .audio)
    static let wma  = Format("wma", "WMA", kind: .audio)
    static let aac  = Format("aac", "AAC", kind: .audio)
    static let caf  = Format("caf", "CAF", kind: .audio)
    static let amr  = Format("amr", "AMR", kind: .audio)

    // Documents
    static let pdf  = Format("pdf", "PDF", kind: .pdf, utType: "com.adobe.pdf")
    static let docx = Format("docx", "Word", kind: .document)
    static let doc  = Format("doc", "Word 97", kind: .document)
    static let odt  = Format("odt", "OpenDocument", kind: .document)
    static let rtf  = Format("rtf", "RTF", kind: .document)
    static let rtfd = Format("rtfd", "RTFD", kind: .document)
    static let txt  = Format("txt", "Plain text", ["txt", "text"], kind: .document)
    static let md   = Format("md", "Markdown", ["md", "markdown"], kind: .document)
    static let html = Format("html", "HTML", ["html", "htm"], kind: .document)
    static let epub = Format("epub", "EPUB", kind: .document)
    static let tex  = Format("tex", "LaTeX", kind: .document)
    static let textClipping = Format("textclipping", "Text clipping", kind: .document)

    // Slides
    static let pptx = Format("pptx", "PowerPoint", kind: .presentation)
    static let ppt  = Format("ppt", "PowerPoint 97", kind: .presentation)
    static let odp  = Format("odp", "OpenDocument slides", kind: .presentation)

    // Spreadsheets
    static let xlsx = Format("xlsx", "Excel", kind: .spreadsheet)
    static let xls  = Format("xls", "Excel 97", kind: .spreadsheet)
    static let ods  = Format("ods", "OpenDocument sheet", kind: .spreadsheet)
    static let csv  = Format("csv", "CSV", kind: .spreadsheet)
    static let tsv  = Format("tsv", "TSV", ["tsv", "tab"], kind: .spreadsheet)
    static let json = Format("json", "JSON", kind: .spreadsheet)

    // Subtitles
    static let srt  = Format("srt", "SubRip", kind: .subtitle)
    static let vtt  = Format("vtt", "WebVTT", kind: .subtitle)
    static let ass  = Format("ass", "ASS/SSA", ["ass", "ssa"], kind: .subtitle)
    static let sbv  = Format("sbv", "SBV", kind: .subtitle)
    static let sub  = Format("sub", "MicroDVD", kind: .subtitle)

    // Archives
    static let zip  = Format("zip", "ZIP", kind: .archive)
    static let tar  = Format("tar", "TAR", kind: .archive)
    static let tgz  = Format("tgz", "TAR.GZ", ["tar.gz", "tgz"], kind: .archive)
    static let tbz2 = Format("tbz2", "TAR.BZ2", ["tar.bz2", "tbz2", "tbz"], kind: .archive)
    static let txz  = Format("txz", "TAR.XZ", ["tar.xz", "txz"], kind: .archive)
    static let sevenZ = Format("7z", "7-Zip", kind: .archive)
    static let rar  = Format("rar", "RAR", kind: .archive)
    static let gz   = Format("gz", "GZIP", kind: .archive)
    static let bz2  = Format("bz2", "BZIP2", kind: .archive)
    static let xz   = Format("xz", "XZ", kind: .archive)
    static let folderFormat = Format("folder", "Folder", kind: .folder)

    static let formats: [Format] = [
        png, jpg, heic, tiff, gif, bmp, webp, avif, jp2, ico, icns, psd, svg, tga, raw,
        mp4, mov, m4v, mkv, avi, webm, wmv, flv, mpg, gp3, ts, ogv,
        mp3, m4a, wav, aiff, flac, ogg, opus, wma, aac, caf, amr,
        pdf, docx, doc, odt, rtf, rtfd, txt, md, html, epub, tex, textClipping,
        pptx, ppt, odp,
        xlsx, xls, ods, csv, tsv, json,
        srt, vtt, ass, sbv, sub,
        zip, tar, tgz, tbz2, txz, sevenZ, rar, gz, bz2, xz,
    ]

    private static let formatByExt: [String: Format] = {
        var map: [String: Format] = [:]
        for f in formats { for e in f.exts { map[e] = f } }
        return map
    }()

    static func format(forExtension ext: String) -> Format? { formatByExt[ext.lowercased()] }

    static func format(for url: URL) -> Format? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           url.pathExtension.lowercased() != "rtfd" {
            return folderFormat
        }
        let name = url.lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz"] where name.hasSuffix("." + compound) {
            return formatByExt[compound]
        }
        return formatByExt[url.pathExtension.lowercased()]
    }

    static func kind(for url: URL) -> FileKind { format(for: url)?.kind ?? .other }

    // MARK: Conversions

    /// Source formats grouped by the targets they can reach.
    static func conversions(from source: Format) -> [Conversion] {
        var out: [Conversion] = []
        func add(_ target: Format, _ backends: [Backend]) {
            guard target != source, !backends.isEmpty else { return }
            out.append(Conversion(target: target, backends: backends))
        }

        switch source.kind {
        case .image:
            for t in [png, jpg, heic, tiff, gif, bmp, jp2, ico, icns, pdf] { add(t, [.native]) }
            add(webp, [.native, .cwebp, .ffmpeg])
            add(avif, [.native, .ffmpeg])
            add(tga, [.native, .ffmpeg])
        case .video:
            for t in [mp4, mov, m4v, m4a, wav, aiff, flac, aac] { add(t, [.native, .ffmpeg]) }
            for t in [mkv, avi, webm, wmv, gif, mp3, ogg] { add(t, [.ffmpeg]) }
        case .audio:
            for t in [m4a, wav, aiff, caf, flac, aac] { add(t, [.native, .ffmpeg]) }
            for t in [mp3, ogg, opus] { add(t, [.ffmpeg]) }
        case .document:
            let nativeRead: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "txt", "md", "html", "textclipping"]
            let pandocRead: Set<String> = ["docx", "odt", "rtf", "txt", "md", "html", "epub", "tex"]
            let sofficeRead: Set<String> = ["docx", "doc", "odt", "rtf", "txt", "html"]
            func readers(_ order: [Backend]) -> [Backend] {
                order.filter { b in
                    switch b {
                    case .native: return nativeRead.contains(source.id)
                    case .pandoc: return pandocRead.contains(source.id)
                    case .soffice: return sofficeRead.contains(source.id)
                    default: return false
                    }
                }
            }
            add(pdf, readers([.soffice, .native]))
            for t in [docx, odt, rtf, txt, html] { add(t, readers([.native, .pandoc])) }
            add(md, readers([.pandoc, .native]))
            add(epub, readers([.pandoc]))
        case .presentation:
            for t in [pdf, pptx, odp, png, jpg] { add(t, [.soffice]) }
        case .spreadsheet:
            let textSource = ["csv", "tsv", "json"].contains(source.id)
            for t in [csv, tsv, json, html] { add(t, textSource ? [.native] : [.soffice]) }
            for t in [xlsx, ods, pdf] { add(t, [.soffice]) }
        case .subtitle:
            let nativeSource = ["srt", "vtt", "sbv"].contains(source.id)
            for t in [srt, vtt, txt] { add(t, nativeSource ? [.native, .ffmpeg] : [.ffmpeg]) }
            add(ass, [.ffmpeg])
        case .archive:
            add(folderFormat, [.native])
            for t in [zip, tgz, txz] { add(t, [.native]) }
            add(sevenZ, [.sevenZip])
        case .pdf:
            for t in [png, jpg, tiff, heic, txt, html, rtf] { add(t, [.native]) }
            add(webp, [.native, .cwebp, .ffmpeg])
            for t in [docx, pptx, xlsx] { add(t, [.soffice]) }
            add(md, [.pandoc])
            add(epub, [.pandoc])
        case .folder:
            for t in [zip, tgz, txz] { add(t, [.native]) }
            add(sevenZ, [.sevenZip])
        case .other:
            break
        }
        return out
    }

    /// Total number of distinct source → target conversion paths the catalog offers.
    static var conversionPathCount: Int {
        formats.reduce(0) { $0 + conversions(from: $1).count }
    }

    /// Conversions shared by every file in a selection.
    static func conversions(for urls: [URL]) -> [Conversion] {
        guard let first = urls.first, let firstFormat = format(for: first) else { return [] }
        var common = conversions(from: firstFormat)
        for url in urls.dropFirst() {
            guard let f = format(for: url) else { return [] }
            let these = Set(conversions(from: f))
            common = common.filter { these.contains($0) }
        }
        return common
    }

    // MARK: Tools

    static let tools: [Tool] = [
        // Images
        Tool("image.compress", "Compress", symbol: "arrow.down.right.and.arrow.up.left", kinds: [.image]),
        Tool("image.crop", "Crop…", symbol: "crop", kinds: [.image]),
        Tool("image.resize", "Resize…", symbol: "arrow.up.left.and.arrow.down.right", kinds: [.image]),
        Tool("image.rotate", "Rotate 90°", symbol: "rotate.right", kinds: [.image]),
        Tool("image.flip", "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", kinds: [.image]),
        Tool("image.grayscale", "Grayscale", symbol: "circle.lefthalf.filled", kinds: [.image]),
        Tool("image.removebg", "Remove background", symbol: "person.crop.rectangle.badge.xmark", kinds: [.image]),
        Tool("image.icon", "Make app icon", symbol: "app.badge", kinds: [.image]),
        Tool("image.merge", "Combine into PDF", symbol: "doc.on.doc", kinds: [.image], multiFile: true),
        // Video
        Tool("video.compress", "Compress", symbol: "arrow.down.right.and.arrow.up.left", kinds: [.video], backends: [.ffmpeg]),
        Tool("video.trim", "Trim…", symbol: "scissors", kinds: [.video], backends: [.ffmpeg, .native]),
        Tool("video.split", "Split in half", symbol: "rectangle.split.2x1", kinds: [.video], backends: [.ffmpeg]),
        Tool("video.audio", "Extract audio", symbol: "waveform", kinds: [.video], backends: [.ffmpeg, .native]),
        Tool("video.mute", "Mute", symbol: "speaker.slash", kinds: [.video], backends: [.ffmpeg]),
        Tool("video.frame", "Thumbnail", symbol: "photo", kinds: [.video]),
        Tool("video.speed", "Speed 2×", symbol: "hare", kinds: [.video], backends: [.ffmpeg]),
        Tool("video.rotate", "Rotate 90°", symbol: "rotate.right", kinds: [.video], backends: [.ffmpeg]),
        Tool("video.merge", "Join videos", symbol: "film.stack", kinds: [.video], backends: [.ffmpeg], multiFile: true),
        // Audio
        Tool("audio.compress", "Compress", symbol: "arrow.down.right.and.arrow.up.left", kinds: [.audio], backends: [.ffmpeg, .native]),
        Tool("audio.trim", "Trim…", symbol: "scissors", kinds: [.audio], backends: [.ffmpeg, .native]),
        Tool("audio.split", "Split in half", symbol: "rectangle.split.2x1", kinds: [.audio], backends: [.ffmpeg]),
        Tool("audio.normalize", "Normalize loudness", symbol: "slider.horizontal.3", kinds: [.audio], backends: [.ffmpeg]),
        Tool("audio.mono", "Make mono", symbol: "speaker.wave.1", kinds: [.audio], backends: [.ffmpeg]),
        Tool("audio.metadata", "Edit metadata…", symbol: "tag", kinds: [.audio], backends: [.ffmpeg]),
        Tool("audio.merge", "Join audio", symbol: "music.note.list", kinds: [.audio], backends: [.ffmpeg], multiFile: true),
        // PDF
        Tool("pdf.compress", "Compress", symbol: "arrow.down.right.and.arrow.up.left", kinds: [.pdf]),
        Tool("pdf.merge", "Merge PDFs", symbol: "doc.on.doc", kinds: [.pdf], multiFile: true),
        Tool("pdf.split", "Split pages", symbol: "rectangle.split.2x1", kinds: [.pdf]),
        Tool("pdf.rotate", "Rotate 90°", symbol: "rotate.right", kinds: [.pdf]),
        Tool("pdf.text", "Extract text", symbol: "text.quote", kinds: [.pdf]),
        Tool("pdf.ocr", "OCR (searchable)", symbol: "text.viewfinder", kinds: [.pdf]),
        Tool("pdf.lock", "Lock with password…", symbol: "lock", kinds: [.pdf]),
        Tool("pdf.unlock", "Remove password…", symbol: "lock.open", kinds: [.pdf]),
        Tool("pdf.metadata", "Edit metadata…", symbol: "tag", kinds: [.pdf]),
        // Any file
        Tool("any.stripmeta", "Strip metadata", symbol: "eye.slash", kinds: [.image, .video, .audio, .pdf], backends: [.native]),
        Tool("any.zip", "Zip", symbol: "archivebox", kinds: []),
        Tool("any.checksum", "SHA-256 to clipboard", symbol: "number", kinds: []),
    ]

    static func tools(for urls: [URL]) -> [Tool] {
        let kinds = Set(urls.map(kind(for:)))
        guard !kinds.isEmpty else { return [] }
        return tools.filter { tool in
            if tool.multiFile && urls.count < 2 { return false }
            if tool.kinds.isEmpty { return true }
            return kinds.isSubset(of: tool.kinds)
        }
    }

    // MARK: Actions

    static let actions: [FileAction] = [
        FileAction(id: "airdrop", name: "AirDrop", symbol: "wifi"),
        FileAction(id: "float", name: "Float", symbol: "macwindow.on.rectangle"),
        FileAction(id: "copy", name: "Copy", symbol: "doc.on.clipboard"),
        FileAction(id: "move", name: "Move…", symbol: "folder"),
        FileAction(id: "copypath", name: "Copy Path", symbol: "link"),
        FileAction(id: "terminal", name: "Terminal", symbol: "terminal"),
    ]
}
