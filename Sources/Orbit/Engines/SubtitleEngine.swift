import Foundation

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleEngine {

    // MARK: Parsing

    static func parse(_ text: String, ext: String) throws -> [SubtitleCue] {
        switch ext.lowercased() {
        case "srt": return parseSRT(text)
        case "vtt": return parseVTT(text)
        case "sbv": return parseSBV(text)
        default: throw OrbitError("Unsupported subtitle format .\(ext)")
        }
    }

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        blocks(text).compactMap { lines in
            var lines = lines
            if lines.first.map({ Int($0.trimmingCharacters(in: .whitespaces)) != nil }) == true { lines.removeFirst() }
            guard let timing = lines.first, let (s, e) = parseTiming(timing) else { return nil }
            return SubtitleCue(start: s, end: e, text: lines.dropFirst().joined(separator: "\n"))
        }
    }

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        blocks(text).compactMap { lines in
            guard let idx = lines.firstIndex(where: { $0.contains("-->") }), let (s, e) = parseTiming(lines[idx]) else { return nil }
            let body = lines[(idx + 1)...].joined(separator: "\n")
            return SubtitleCue(start: s, end: e, text: stripTags(body))
        }
    }

    static func parseSBV(_ text: String) -> [SubtitleCue] {
        blocks(text).compactMap { lines in
            guard let timing = lines.first else { return nil }
            let parts = timing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let s = parseTime(parts[0]), let e = parseTime(parts[1]) else { return nil }
            return SubtitleCue(start: s, end: e, text: lines.dropFirst().joined(separator: "\n"))
        }
    }

    private static func blocks(_ text: String) -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").map { block in
            block.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        }.filter { !$0.isEmpty && !($0.count == 1 && $0[0].hasPrefix("WEBVTT")) }
            .filter { !$0[0].hasPrefix("WEBVTT") && !$0[0].hasPrefix("NOTE") && !$0[0].hasPrefix("STYLE") }
    }

    private static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let endPart = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let s = parseTime(parts[0].trimmingCharacters(in: .whitespaces)), let e = parseTime(endPart) else { return nil }
        return (s, e)
    }

    /// "00:01:02,500", "00:01:02.500", "01:02.500" or "1:02.5"
    static func parseTime(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    // MARK: Writing

    static func formatTime(_ t: Double, separator: String) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60_000, s = (ms % 60_000) / 1000, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, f)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(formatTime(c.start, separator: ",")) --> \(formatTime(c.end, separator: ","))\n\(c.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(formatTime(c.start, separator: ".")) --> \(formatTime(c.end, separator: "."))\n\(c.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { stripTags($0.text).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n"
    }

    // MARK: Conversion

    static func convert(_ url: URL, to target: Format, backend: Backend) throws -> URL {
        let out = OutputPaths.output(for: url, ext: target.ext)
        if backend == .native {
            let cues = try parse(try String(contentsOf: url), ext: url.pathExtension)
            let text: String
            switch target.id {
            case "srt": text = srt(cues)
            case "vtt": text = vtt(cues)
            case "txt": text = plainText(cues)
            default: throw OrbitError("Can't write .\(target.ext) natively.")
            }
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        guard let exe = Backends.path(for: .ffmpeg) else { throw MissingBackendError(backend: .ffmpeg) }
        if target.id == "txt" {
            let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("sub.srt")
            try runProcess(exe, ["-y", "-loglevel", "error", "-i", url.path, tmp.path])
            try plainText(parseSRT(try String(contentsOf: tmp))).write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        try runProcess(exe, ["-y", "-loglevel", "error", "-i", url.path, out.path])
        return out
    }
}
