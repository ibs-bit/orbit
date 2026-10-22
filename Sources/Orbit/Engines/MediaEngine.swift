import AVFoundation
import AppKit

/// Video and audio conversion via ffmpeg when installed, AVFoundation otherwise.
enum MediaEngine {

    static func duration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var result = 0.0
        Task.detached {
            if let d = try? await asset.load(.duration) { result = CMTimeGetSeconds(d) }
            semaphore.signal()
        }
        semaphore.wait()
        return result.isFinite ? result : 0
    }

    // MARK: ffmpeg

    /// Runs ffmpeg with progress reporting. `args` go between the input and the output.
    static func ffmpeg(input: URL, args: [String], output: URL, job: Job?, inputArgs: [String] = []) throws {
        guard let exe = Backends.path(for: .ffmpeg) else { throw MissingBackendError(backend: .ffmpeg) }
        let total = duration(of: input)
        var all = ["-y", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]
        all += inputArgs + ["-i", input.path] + args + [output.path]
        try runProcess(exe, all) { line in
            guard total > 0, let job else { return }
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) {
                job.progress(us / 1_000_000 / total)
            } else if line.hasPrefix("out_time_ms="), let ms = Double(line.dropFirst("out_time_ms=".count)) {
                job.progress(ms / 1_000_000 / total) // ffmpeg reports microseconds here despite the name
            }
        }
    }

    static func ffmpegArgs(for target: Format) -> [String] {
        switch target.id {
        case "mp4", "m4v": return ["-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov": return ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case "mkv": return ["-c:v", "libx264", "-preset", "medium", "-crf", "22", "-c:a", "aac", "-b:a", "192k"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "3"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        case "wmv": return ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2"]
        case "gif": return ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer", "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "aac": return ["-vn", "-c:a", "aac", "-b:a", "192k", "-f", "adts"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "caf": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "webp": return ["-c:v", "libwebp", "-quality", "85"]
        case "avif": return ["-c:v", "libaom-av1", "-crf", "30", "-still-picture", "1"]
        default: return []
        }
    }

    // MARK: Native (AVFoundation)

    /// afconvert arguments for audio targets Core Audio can write.
    static func afconvertArgs(for target: Format, bitrate: Int = 192_000) -> [String]? {
        switch target.id {
        case "wav": return ["-f", "WAVE", "-d", "LEI16"]
        case "aiff": return ["-f", "AIFF", "-d", "BEI16"]
        case "caf": return ["-f", "caff", "-d", "LEI16"]
        case "m4a": return ["-f", "m4af", "-d", "aac", "-b", String(bitrate)]
        case "aac": return ["-f", "adts", "-d", "aac", "-b", String(bitrate)]
        case "flac": return ["-f", "flac", "-d", "flac"]
        default: return nil
        }
    }

    /// Converts audio with Apple's afconvert (ships with macOS, runs out of process).
    static func afconvert(_ input: URL, to out: URL, target: Format, bitrate: Int = 192_000) throws {
        guard let args = afconvertArgs(for: target, bitrate: bitrate) else { throw MissingBackendError(backend: .ffmpeg) }
        try runProcess("/usr/bin/afconvert", args + [input.path, out.path])
    }

    static func nativeConvert(_ url: URL, to target: Format, job: Job?) throws -> URL {
        let out = OutputPaths.output(for: url, ext: target.ext)
        switch target.id {
        case "mp4": try export(url, to: out, fileType: .mp4, preset: AVAssetExportPresetHighestQuality, job: job)
        case "mov": try export(url, to: out, fileType: .mov, preset: AVAssetExportPresetHighestQuality, job: job)
        case "m4v": try export(url, to: out, fileType: .m4v, preset: AVAssetExportPresetHighestQuality, job: job)
        case "wav", "aiff", "caf", "m4a", "aac", "flac":
            if Catalog.kind(for: url) == .video {
                // Pull the audio track out with AVFoundation first, then let afconvert re-wrap it.
                let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("audio.m4a")
                try export(url, to: tmp, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, job: job)
                if target.id == "m4a" { try FileManager.default.moveItem(at: tmp, to: out) } else { try afconvert(tmp, to: out, target: target) }
            } else {
                try afconvert(url, to: out, target: target)
            }
        default: throw MissingBackendError(backend: .ffmpeg)
        }
        return out
    }

    static func export(_ url: URL, to out: URL, fileType: AVFileType, preset: String, job: Job?,
                       timeRange: CMTimeRange? = nil, audioOnly: Bool = false) throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OrbitError("This file can't be exported without ffmpeg.")
        }
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            job?.progress(Double(session.progress))
        }
        if let error = session.error { throw error }
        guard session.status == .completed else { throw OrbitError("Export did not complete.") }
    }

    static func thumbnail(_ url: URL, at seconds: Double = 1) throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: min(seconds, max(0, duration(of: url) - 0.1)), preferredTimescale: 600)
        return try generator.copyCGImage(at: t, actualTime: nil)
    }

    // MARK: Conversion entry point

    static func convert(_ url: URL, to target: Format, backend: Backend, job: Job?) throws -> URL {
        if backend == .native { return try nativeConvert(url, to: target, job: job) }
        let out = OutputPaths.output(for: url, ext: target.ext)
        try ffmpeg(input: url, args: ffmpegArgs(for: target), output: out, job: job)
        return out
    }
}
