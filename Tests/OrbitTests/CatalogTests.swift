import XCTest
@testable import Orbit

final class CatalogTests: XCTestCase {
    func testOffersAtLeast275ConversionPaths() {
        XCTAssertGreaterThanOrEqual(Catalog.conversionPathCount, 275, "Tangerine advertises 275; we offer \(Catalog.conversionPathCount)")
    }

    func testOffersAtLeast26ToolsAnd6Actions() {
        XCTAssertGreaterThanOrEqual(Catalog.tools.count, 26)
        XCTAssertEqual(Catalog.actions.count, 6)
        XCTAssertEqual(Catalog.actions.map(\.name), ["AirDrop", "Float", "Copy", "Move…", "Copy Path", "Terminal"])
    }

    func testEveryToolFamilyCoversTangerineHeadlineTools() {
        let names = Set(Catalog.tools.map { $0.name.lowercased() })
        for needle in ["compress", "crop", "trim", "split", "merge", "metadata"] {
            XCTAssertTrue(names.contains { $0.contains(needle) }, "missing a \(needle) tool")
        }
    }

    func testFormatLookupHandlesCompoundExtensions() {
        XCTAssertEqual(Catalog.format(for: URL(fileURLWithPath: "/tmp/a.tar.gz"))?.id, "tgz")
        XCTAssertEqual(Catalog.format(for: URL(fileURLWithPath: "/tmp/a.JPEG"))?.id, "jpg")
        XCTAssertEqual(Catalog.format(for: URL(fileURLWithPath: "/tmp/a.dng"))?.id, "raw")
        XCTAssertNil(Catalog.format(for: URL(fileURLWithPath: "/tmp/a.unknownext")))
    }

    func testNoConversionTargetsItself() {
        for f in Catalog.formats {
            XCTAssertFalse(Catalog.conversions(from: f).contains { $0.target == f }, "\(f.id) converts to itself")
        }
    }

    func testMixedSelectionOnlyKeepsCommonTargets() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mp4")]
        let ids = Catalog.conversions(for: urls).map(\.id)
        XCTAssertTrue(ids.contains("gif"))
        XCTAssertFalse(ids.contains("mp3"))
        XCTAssertFalse(ids.contains("heic"))
    }

    func testToolsForMultiFileSelections() {
        let one = Catalog.tools(for: [URL(fileURLWithPath: "/tmp/a.pdf")]).map(\.id)
        let two = Catalog.tools(for: [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")]).map(\.id)
        XCTAssertFalse(one.contains("pdf.merge"))
        XCTAssertTrue(two.contains("pdf.merge"))
        XCTAssertTrue(two.contains("any.zip"))
    }

    func testUniqueNaming() throws {
        let dir = try OutputPaths.temporaryDirectory()
        let a = dir.appendingPathComponent("photo.png")
        try Data().write(to: a)
        XCTAssertEqual(OutputPaths.unique(a).lastPathComponent, "photo 2.png")
        try Data().write(to: dir.appendingPathComponent("photo 2.png"))
        XCTAssertEqual(OutputPaths.unique(a).lastPathComponent, "photo 3.png")
        let t = dir.appendingPathComponent("site.tar.gz")
        try Data().write(to: t)
        XCTAssertEqual(OutputPaths.unique(t).lastPathComponent, "site 2.tar.gz")
        XCTAssertEqual(OutputPaths.baseName(of: t), "site")
    }

    func testTimecodeParsing() {
        XCTAssertEqual(Timecode.parse("90"), 90)
        XCTAssertEqual(Timecode.parse("1:30"), 90)
        XCTAssertEqual(Timecode.parse("0:01:30.5"), 90.5)
        XCTAssertNil(Timecode.parse("abc"))
        XCTAssertEqual(Timecode.format(90), "1:30")
        XCTAssertEqual(Timecode.format(3661), "1:01:01")
    }
}
