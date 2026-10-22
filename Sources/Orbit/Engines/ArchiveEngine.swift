import Foundation

enum ArchiveEngine {
    private static let tar = "/usr/bin/tar"
    private static let zip = "/usr/bin/zip"

    static func isSingleFileCompression(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz"] where name.hasSuffix(compound) { return false }
        return ["gz", "bz2", "xz"].contains(url.pathExtension.lowercased())
    }

    /// Extracts an archive into a new folder next to it (or the configured output folder).
    static func extract(_ url: URL, into directory: URL? = nil) throws -> URL {
        let dest = OutputPaths.output(for: url, ext: "", directory: directory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        if isSingleFileCompression(url) {
            let tool = ["gz": "/usr/bin/gzip", "bz2": "/usr/bin/bzip2", "xz": "/usr/bin/xz"][ext]!
            let outName = url.deletingPathExtension().lastPathComponent
            try decompress(tool, url, to: dest.appendingPathComponent(outName))
            return dest
        }
        if ext == "7z", let seven = Backends.path(for: .sevenZip) {
            // -snl- stores symlinks as plain files so an archive can't link outside the folder.
            try runProcess(seven, ["x", "-y", "-snl-", "-o\(dest.path)", "--", url.path])
        } else {
            // bsdtar reads zip/tar/7z/rar and refuses ".." and extraction through symlinks.
            try runProcess(tar, ["-xf", url.path, "-C", dest.path])
        }
        try removeEscapingSymlinks(in: dest)
        return dest
    }

    /// Deletes any symlink inside `root` that resolves outside it.
    static func removeEscapingSymlinks(in root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let item as URL in e {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = item.resolvingSymlinksInPath().path
            if !(target + "/").hasPrefix(rootPath + "/") { try FileManager.default.removeItem(at: item) }
        }
    }

    private static func decompress(_ tool: String, _ input: URL, to output: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-dc", input.path]
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        p.standardOutput = handle
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        try handle.close()
        guard p.terminationStatus == 0 else {
            throw ProcessError(command: (tool as NSString).lastPathComponent, status: p.terminationStatus,
                               stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
    }

    /// Packs files or folders into an archive of the given format.
    static func create(_ urls: [URL], format: Format, name: String? = nil) throws -> URL {
        guard let first = urls.first else { throw OrbitError("Nothing to archive.") }
        var sources = urls
        var parent = first.deletingLastPathComponent()
        var staging: URL? = nil
        if Set(urls.map { $0.deletingLastPathComponent().path }).count > 1 {
            // Mixed folders: stage copies so relative paths are flat.
            let tmp = try OutputPaths.temporaryDirectory()
            for u in urls { try FileManager.default.copyItem(at: u, to: tmp.appendingPathComponent(u.lastPathComponent)) }
            sources = urls.map { tmp.appendingPathComponent($0.lastPathComponent) }
            parent = tmp
            staging = tmp
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let baseName = name ?? (urls.count == 1 ? OutputPaths.baseName(of: first) : "Archive")
        let out = OutputPaths.unique(OutputPaths.directory(for: first).appendingPathComponent(baseName + "." + format.ext))
        let names = sources.map(\.lastPathComponent)
        switch format.id {
        case "zip": try runProcess(zip, ["-r", "-y", "-q", "-X", "--", out.path] + names, cwd: parent)
        case "tar": try runProcess(tar, ["-cf", out.path, "-C", parent.path, "--"] + names)
        case "tgz": try runProcess(tar, ["-czf", out.path, "-C", parent.path, "--"] + names)
        case "tbz2": try runProcess(tar, ["-cjf", out.path, "-C", parent.path, "--"] + names)
        case "txz": try runProcess(tar, ["-cJf", out.path, "-C", parent.path, "--"] + names)
        case "7z":
            guard let seven = Backends.path(for: .sevenZip) else { throw MissingBackendError(backend: .sevenZip) }
            try runProcess(seven, ["a", "-y", "--", out.path] + names, cwd: parent)
        default: throw OrbitError("Unsupported archive format \(format.name).")
        }
        return out
    }

    /// Archive → archive (or folder) conversion.
    static func convert(_ url: URL, to target: Format) throws -> URL {
        if target.id == "folder" { return try extract(url) }
        let tmp = try OutputPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let extracted = try extract(url, into: tmp)
        let contents = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !contents.isEmpty else { throw OrbitError("Archive is empty.") }
        let out = OutputPaths.unique(OutputPaths.directory(for: url).appendingPathComponent(OutputPaths.baseName(of: url) + "." + target.ext))
        let names = contents.map(\.lastPathComponent)
        switch target.id {
        case "zip": try runProcess(zip, ["-r", "-y", "-q", "-X", "--", out.path] + names, cwd: extracted)
        case "tgz": try runProcess(tar, ["-czf", out.path, "-C", extracted.path, "--"] + names)
        case "txz": try runProcess(tar, ["-cJf", out.path, "-C", extracted.path, "--"] + names)
        case "tar": try runProcess(tar, ["-cf", out.path, "-C", extracted.path, "--"] + names)
        case "7z":
            guard let seven = Backends.path(for: .sevenZip) else { throw MissingBackendError(backend: .sevenZip) }
            try runProcess(seven, ["a", "-y", "--", out.path] + names, cwd: extracted)
        default: throw OrbitError("Unsupported archive format \(target.name).")
        }
        return out
    }
}
