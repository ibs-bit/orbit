import Foundation

enum OutputLocation: String, CaseIterable, Identifiable {
    case sameFolder, downloads, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sameFolder: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }
}

enum OutputPaths {
    /// Directory new files are written to for a given source.
    static func directory(for source: URL) -> URL {
        switch Preferences.outputLocation {
        case .sameFolder: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }

    /// Base name of a file without its (possibly compound) extension.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(compound) {
            return String(name.dropLast(compound.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// A unique destination next to (or in the configured folder for) `source`.
    static func output(for source: URL, ext: String, suffix: String? = nil, directory: URL? = nil) -> URL {
        var name = baseName(of: source)
        if let suffix { name += "-" + suffix }
        let dir = directory ?? self.directory(for: source)
        let candidate = ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name + "." + ext)
        return unique(candidate)
    }

    /// Appends " 2", " 3", … until the path does not exist.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var base = name, ext = ""
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(compound) {
            base = String(name.dropLast(compound.count)); ext = compound
        }
        if ext.isEmpty, !url.pathExtension.isEmpty {
            base = url.deletingPathExtension().lastPathComponent
            ext = "." + url.pathExtension
        }
        var n = 2
        while true {
            let c = dir.appendingPathComponent("\(base) \(n)\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbit", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
