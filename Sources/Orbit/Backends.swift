import Foundation

/// Locates optional command-line helpers (ffmpeg, pandoc, LibreOffice, 7-Zip).
enum Backends {
    private static var cache: [Backend: String?] = [:]
    private static let lock = NSLock()

    private static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]

    static func refresh() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    static func path(for backend: Backend) -> String? {
        if backend == .native { return "" }
        lock.lock()
        if let cached = cache[backend] { lock.unlock(); return cached }
        lock.unlock()
        let found = locate(backend)
        lock.lock(); cache[backend] = found; lock.unlock()
        return found
    }

    static func isAvailable(_ backend: Backend) -> Bool { path(for: backend) != nil }

    /// First available backend from a preference-ordered list, or nil.
    static func firstAvailable(_ backends: [Backend]) -> Backend? {
        backends.first(where: isAvailable)
    }

    private static func locate(_ backend: Backend) -> String? {
        let names: [String]
        switch backend {
        case .native: return ""
        case .ffmpeg: names = ["ffmpeg"]
        case .pandoc: names = ["pandoc"]
        case .sevenZip: names = ["7zz", "7z", "7za"]
        case .cwebp: names = ["cwebp"]
        case .soffice:
            let appPaths = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            if let p = appPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
            names = ["soffice", "libreoffice"]
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchDirs + pathDirs {
            for n in names {
                let p = (dir as NSString).appendingPathComponent(n)
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

struct ProcessError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String
    var errorDescription: String? {
        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
        return "\(command) failed (\(status)): \(tail)"
    }
}

/// Runs a command, streaming each stdout line to `onLine`. Throws when the exit status is non-zero.
@discardableResult
func runProcess(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                environment: [String: String]? = nil,
                onLine: ((String) -> Void)? = nil) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    if let environment { env.merge(environment) { $1 } }
    process.environment = env

    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    var outData = Data(), errData = Data()
    let dataLock = NSLock()
    var lineBuffer = ""
    outPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        dataLock.lock()
        outData.append(d)
        if let onLine, let s = String(data: d, encoding: .utf8) {
            lineBuffer += s
            while let r = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(lineBuffer[..<r])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: r)...])
                if !line.isEmpty { onLine(line) }
            }
        }
        dataLock.unlock()
    }
    errPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        dataLock.lock(); errData.append(d); dataLock.unlock()
    }

    try process.run()
    process.waitUntilExit()
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    dataLock.lock()
    outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
    errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
    let result = ProcessResult(status: process.terminationStatus,
                               stdout: String(data: outData, encoding: .utf8) ?? "",
                               stderr: String(data: errData, encoding: .utf8) ?? "")
    dataLock.unlock()
    if !result.ok {
        throw ProcessError(command: (executable as NSString).lastPathComponent, status: result.status, stderr: result.stderr)
    }
    return result
}
