import XCTest
import AppKit
import PDFKit
@testable import Orbit

final class EngineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = try OutputPaths.temporaryDirectory()
        UserDefaults.standard.set(OutputLocation.sameFolder.rawValue, forKey: "outputLocation")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeImage(name: String = "test.png", alpha: Bool = true) throws -> URL {
        let ctx = ImageEngine.context(width: 64, height: 40)!
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 40))
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 40))
        var img = ctx.makeImage()!
        if !alpha { img = ImageEngine.flattened(img) }
        let url = dir.appendingPathComponent(name)
        try ImageEngine.write(img, to: url, format: Catalog.png)
        return url
    }

    func testImageConversionsRoundTrip() throws {
        let png = try makeImage()
        for target in [Catalog.jpg, Catalog.heic, Catalog.tiff, Catalog.gif, Catalog.bmp, Catalog.pdf, Catalog.ico, Catalog.icns] {
            let out = try ImageEngine.convert(png, to: target)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), target.id)
            XCTAssertEqual(out.pathExtension, target.ext)
            if target.kind == .image, target.id != "icns" {
                let back = try ImageEngine.load(out)
                XCTAssertEqual(back.width, 64, target.id)
            }
        }
        XCTAssertNotNil(PDFDocument(url: dir.appendingPathComponent("test.pdf")))
    }

    func testImageEdits() throws {
        let img = try ImageEngine.load(try makeImage())
        XCTAssertEqual(ImageEngine.rotated90(img).width, 40)
        XCTAssertEqual(ImageEngine.scaled(img, factor: 0.5).width, 32)
        XCTAssertEqual(ImageEngine.squareCropped(img).width, 40)
        XCTAssertEqual(ImageEngine.cropped(img, aspect: 1).height, 40)
        XCTAssertEqual(ImageEngine.flippedHorizontally(img).width, 64)
        XCTAssertEqual(ImageEngine.grayscale(img).width, 64)
    }

    func testPDFPipeline() throws {
        let text = NSAttributedString(string: String(repeating: "Hello Orbit. ", count: 2000), attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let pdf = dir.appendingPathComponent("doc.pdf")
        try DocumentEngine.writePDF(text, to: pdf)
        let doc = try PDFEngine.open(pdf)
        XCTAssertGreaterThan(doc.pageCount, 1)

        XCTAssertTrue(try PDFEngine.text(pdf, ocrIfEmpty: false).contains("Hello Orbit"))

        let images = try PDFEngine.pagesToImages(pdf, format: Catalog.png)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.path, isDirectory: &isDir) && isDir.boolValue)

        let split = try PDFEngine.split(pdf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: split.path).count, doc.pageCount)

        let merged = try PDFEngine.merge([pdf, pdf])
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, doc.pageCount * 2)

        let rotated = try PDFEngine.rotate(pdf)
        XCTAssertEqual(PDFDocument(url: rotated)?.page(at: 0)?.rotation, 90)

        let locked = try PDFEngine.lock(pdf, password: "secret")
        XCTAssertTrue(PDFDocument(url: locked)!.isLocked)
        let unlocked = try PDFEngine.unlock(locked, password: "secret")
        XCTAssertFalse(PDFDocument(url: unlocked)!.isLocked)

        let tagged = try PDFEngine.setMetadata(pdf, title: "T", author: "A", subject: "S", keywords: "x, y")
        XCTAssertEqual(PDFEngine.currentMetadata(tagged), ["T", "A", "S", "x, y"])

        let txt = try PDFEngine.convert(pdf, to: Catalog.txt, backend: .native)
        XCTAssertTrue(try String(contentsOf: txt).contains("Hello Orbit"))
        let rtf = try PDFEngine.convert(pdf, to: Catalog.rtf, backend: .native)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rtf.path))
    }

    func testDocumentConversions() throws {
        let md = dir.appendingPathComponent("notes.md")
        try "# Title\n\nSome **bold** text and _italic_.\n\n## Sub\n\n- one\n- two\n".write(to: md, atomically: true, encoding: .utf8)
        for target in [Catalog.docx, Catalog.odt, Catalog.rtf, Catalog.html, Catalog.txt, Catalog.pdf] {
            let out = try DocumentEngine.convertDocument(md, to: target, backend: .native)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), target.id)
            XCTAssertGreaterThan(ImageEngine.fileSize(out), 0, target.id)
        }
        let docx = dir.appendingPathComponent("notes.docx")
        let back = try DocumentEngine.readAttributed(docx)
        XCTAssertTrue(back.string.contains("Title"))
        XCTAssertTrue(back.string.contains("bold"))
        let mdOut = try DocumentEngine.convertDocument(docx, to: Catalog.md, backend: .native)
        XCTAssertTrue(try String(contentsOf: mdOut).contains("# Title"))
    }

    func testSpreadsheetTextConversions() throws {
        let csv = dir.appendingPathComponent("data.csv")
        try "name,age,note\nAda,36,\"likes, commas\"\nBob,41,\"multi\nline\"\n".write(to: csv, atomically: true, encoding: .utf8)
        let rows = try DocumentEngine.readRows(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][2], "likes, commas")
        XCTAssertEqual(rows[2][2], "multi\nline")

        let json = try DocumentEngine.convertSpreadsheet(csv, to: Catalog.json, backend: .native)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["age"] as? Int, 36)

        let tsv = try DocumentEngine.convertSpreadsheet(csv, to: Catalog.tsv, backend: .native)
        XCTAssertTrue(try String(contentsOf: tsv).hasPrefix("name\tage\tnote"))
        let backToCSV = try DocumentEngine.convertSpreadsheet(json, to: Catalog.csv, backend: .native)
        XCTAssertEqual(try DocumentEngine.readRows(backToCSV)[0].sorted(), ["age", "name", "note"])
        let html = try DocumentEngine.convertSpreadsheet(csv, to: Catalog.html, backend: .native)
        XCTAssertTrue(try String(contentsOf: html).contains("<th>name</th>"))
    }

    func testHTMLImportIsOffline() throws {
        let html = """
        <html><head><link rel=stylesheet href="http://evil.test/a.css"><script>alert(1)</script></head>
        <body><h1>Hi</h1><img src="http://evil.test/x.png"><p style="background:url(http://evil.test/b.png)">Body <a href="http://evil.test">link</a></p></body></html>
        """
        let parsed = try DocumentEngine.offlineHTML(html)
        XCTAssertTrue(parsed.string.contains("Hi"))
        XCTAssertTrue(parsed.string.contains("Body"))
        XCTAssertFalse(parsed.string.contains("alert"))
        // A hyperlink attribute is inert; what matters is that nothing was fetched and no script survived.
        if !Backends.isAvailable(.pandoc) {
            var hasLink = false
            parsed.enumerateAttribute(.link, in: NSRange(location: 0, length: parsed.length)) { v, _, _ in if v != nil { hasLink = true } }
            XCTAssertFalse(hasLink)
        }

        // The regex fallback must survive parser tricks: unclosed tags, `/` before attributes, @import.
        let tricky = "<p>Keep</p><img/src=\"http://evil.test/p.png\"><style>@import 'http://evil.test/a.css'; p{background:url(http://evil.test/b.png)}</style><a href='http://evil.test'>x</a><script>fetch('http://evil.test')"
        let out = DocumentEngine.sanitizedHTML(tricky)
        XCTAssertFalse(out.contains("evil.test"), out)
        XCTAssertFalse(out.contains("http://"), out)
        XCTAssertFalse(out.contains("@import"), out)
        XCTAssertFalse(out.contains("fetch"), out)
        XCTAssertTrue(out.contains("Keep"))
    }

    func testEscapingSymlinksAreRemovedAfterExtraction() throws {
        let root = dir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bad"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        try "x".write(to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("good"), withDestinationURL: root.appendingPathComponent("inside.txt"))
        try ArchiveEngine.removeEscapingSymlinks(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("good").path))
    }

    func testSubtitles() throws {
        let srt = dir.appendingPathComponent("s.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\nagain\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try SubtitleEngine.convert(srt, to: Catalog.vtt, backend: .native)
        let vttText = try String(contentsOf: vtt)
        XCTAssertTrue(vttText.hasPrefix("WEBVTT"))
        XCTAssertTrue(vttText.contains("00:00:01.000 --> 00:00:02.500"))
        let back = try SubtitleEngine.convert(vtt, to: Catalog.srt, backend: .native)
        XCTAssertEqual(SubtitleEngine.parseSRT(try String(contentsOf: back)), SubtitleEngine.parseSRT(try String(contentsOf: srt)))
        let txt = try SubtitleEngine.convert(srt, to: Catalog.txt, backend: .native)
        XCTAssertEqual(try String(contentsOf: txt), "Hello\nWorld again\n")
        let sbv = dir.appendingPathComponent("s.sbv")
        try "0:00:01.000,0:00:02.000\nHi\n\n".write(to: sbv, atomically: true, encoding: .utf8)
        XCTAssertEqual(SubtitleEngine.parseSBV(try String(contentsOf: sbv)).first?.text, "Hi")
    }

    func testArchives() throws {
        let folder = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        for format in [Catalog.zip, Catalog.tgz, Catalog.txz, Catalog.tar] {
            let archive = try ArchiveEngine.create([folder], format: format)
            XCTAssertTrue(archive.lastPathComponent.hasSuffix(format.ext), format.id)
            let extracted = try ArchiveEngine.extract(archive, into: dir.appendingPathComponent("x-\(format.id)"))
            let inner = try String(contentsOf: extracted.appendingPathComponent("project/sub/a.txt"))
            XCTAssertEqual(inner, "hello", format.id)
            try FileManager.default.removeItem(at: archive)
        }
        let zip = try ArchiveEngine.create([folder], format: Catalog.zip)
        let tgz = try ArchiveEngine.convert(zip, to: Catalog.tgz)
        XCTAssertTrue(tgz.lastPathComponent.hasSuffix(".tar.gz"))
        let gz = dir.appendingPathComponent("single.txt.gz")
        try runProcess("/usr/bin/gzip", ["-k", "-c", folder.appendingPathComponent("sub/a.txt").path]).stdout.write(to: gz, atomically: true, encoding: .utf8)
        XCTAssertTrue(ArchiveEngine.isSingleFileCompression(gz))
    }

    func testNativeMediaExportWhenPossible() throws {
        // Build a short silent WAV with AVFoundation-free bytes, then export to m4a/aiff natively.
        let wav = dir.appendingPathComponent("tone.wav")
        try makeWAV(to: wav, seconds: 0.5)
        XCTAssertEqual(MediaEngine.duration(of: wav), 0.5, accuracy: 0.05)
        let started = Date()
        let aiff = try MediaEngine.convert(wav, to: Catalog.aiff, backend: .native, job: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "PCM export should be quick")
        XCTAssertGreaterThan(ImageEngine.fileSize(aiff), 1000)
        XCTAssertEqual(MediaEngine.duration(of: aiff), 0.5, accuracy: 0.05)
        let wavBack = try MediaEngine.convert(aiff, to: Catalog.wav, backend: .native, job: nil)
        XCTAssertGreaterThan(ImageEngine.fileSize(wavBack), 1000)
        let m4a = try MediaEngine.convert(wav, to: Catalog.m4a, backend: .native, job: nil)
        XCTAssertGreaterThan(ImageEngine.fileSize(m4a), 500)
        let flac = try MediaEngine.convert(m4a, to: Catalog.flac, backend: .native, job: nil)
        XCTAssertGreaterThan(ImageEngine.fileSize(flac), 500)
    }

    func testFFmpegConversionsIfInstalled() throws {
        try XCTSkipUnless(Backends.isAvailable(.ffmpeg), "ffmpeg not installed")
        let wav = dir.appendingPathComponent("tone.wav")
        try makeWAV(to: wav, seconds: 0.5)
        let mp3 = try MediaEngine.convert(wav, to: Catalog.mp3, backend: .ffmpeg, job: nil)
        XCTAssertGreaterThan(ImageEngine.fileSize(mp3), 1000)
        let png = try makeImage(name: "w.png")
        let webp = try ImageEngine.convert(png, to: Catalog.webp)
        XCTAssertEqual(webp.pathExtension, "webp")
    }

    func testPandocIfInstalled() throws {
        try XCTSkipUnless(Backends.isAvailable(.pandoc), "pandoc not installed")
        let md = dir.appendingPathComponent("p.md")
        try "# Hi\n\nText\n".write(to: md, atomically: true, encoding: .utf8)
        let epub = try DocumentEngine.convertDocument(md, to: Catalog.epub, backend: .pandoc)
        XCTAssertGreaterThan(ImageEngine.fileSize(epub), 1000)
    }

    private func makeWAV(to url: URL, seconds: Double) throws {
        let rate = 44100, frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) / Double(rate) * 440 * 2 * .pi) * 12000)
            pcm.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) })
        }
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        try d.write(to: url)
    }
}
