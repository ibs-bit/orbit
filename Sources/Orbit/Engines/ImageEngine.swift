import AppKit
import ImageIO
import CoreImage
import Vision
import UniformTypeIdentifiers

/// Image decoding, encoding and editing built on ImageIO, CoreGraphics and Vision.
enum ImageEngine {
    static let encodableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func canEncode(_ format: Format) -> Bool {
        guard let ut = format.utType else { return false }
        if ["icns", "pdf", "ico"].contains(format.id) { return true }
        return encodableTypes.contains(ut)
    }

    // MARK: Loading

    /// Loads the first frame of an image with its EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" { return try rasterizeSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw OrbitError("Could not read \(url.lastPathComponent).")
        }
        var maxDim = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            maxDim = max(w, h)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDim, 16),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return img }
        if let img = CGImageSourceCreateImageAtIndex(source, 0, nil) { return img }
        throw OrbitError("Could not decode \(url.lastPathComponent).")
    }

    private static func rasterizeSVG(_ url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { throw OrbitError("Could not read SVG.") }
        let scale = max(1, 2048 / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = NSImage(size: size, flipped: false) { rect in image.draw(in: rect); return true }
        guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw OrbitError("Could not rasterize SVG.") }
        return cg
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: Writing

    static func write(_ image: CGImage, to url: URL, format: Format, quality: Double? = nil) throws {
        switch format.id {
        case "icns": try writeICNS(image, to: url); return
        case "pdf": try writePDF([image], to: url); return
        case "ico": try writeICO(image, to: url); return
        default: break
        }
        guard let ut = format.utType, encodableTypes.contains(ut) else {
            throw MissingBackendError(backend: .ffmpeg)
        }
        var img = image
        if ["jpg", "bmp", "jp2"].contains(format.id), img.hasAlpha { img = flattened(img) }
        if format.id == "ico", max(img.width, img.height) > 256 { img = scaled(img, maxDimension: 256) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, ut as CFString, 1, nil) else {
            throw OrbitError("Could not create \(format.name) file.")
        }
        var props: [CFString: Any] = [:]
        let q = quality ?? defaultQuality(format)
        if let q { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OrbitError("Encoding \(format.name) failed.") }
    }

    private static func defaultQuality(_ f: Format) -> Double? {
        switch f.id {
        case "jpg": return 0.9
        case "heic": return 0.85
        case "webp", "avif": return 0.85
        case "jp2": return 0.9
        default: return nil
        }
    }

    /// ICO container holding a single PNG image (supported since Windows Vista and by every browser).
    static func writeICO(_ image: CGImage, to url: URL) throws {
        let img = max(image.width, image.height) > 256 ? scaled(image, maxDimension: 256) : image
        guard let ut = Catalog.png.utType, let dest = CGImageDestinationCreateWithData(NSMutableData() as CFMutableData, ut as CFString, 1, nil) else {
            throw OrbitError("Could not encode PNG for ICO.")
        }
        let pngData = NSMutableData()
        guard let pngDest = CGImageDestinationCreateWithData(pngData, ut as CFString, 1, nil) else { throw OrbitError("Could not encode PNG for ICO.") }
        _ = dest
        CGImageDestinationAddImage(pngDest, img, nil)
        guard CGImageDestinationFinalize(pngDest) else { throw OrbitError("Could not encode PNG for ICO.") }
        var data = Data()
        func u16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        u16(0); u16(1); u16(1)                                   // reserved, type=icon, count
        data.append(UInt8(img.width >= 256 ? 0 : img.width))     // width (0 = 256)
        data.append(UInt8(img.height >= 256 ? 0 : img.height))   // height
        data.append(0); data.append(0)                           // palette, reserved
        u16(1); u16(32)                                          // planes, bpp
        u32(UInt32(pngData.length)); u32(22)                     // size, offset
        data.append(pngData as Data)
        try data.write(to: url)
    }

    static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let first = images.first else { throw OrbitError("No images.") }
        var box = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OrbitError("Could not create PDF.") }
        for image in images {
            var page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &page, length: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.draw(image, in: page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func writeICNS(_ image: CGImage, to url: URL) throws {
        let tmp = try OutputPaths.temporaryDirectory()
        let iconset = tmp.appendingPathComponent("icon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let square = squareCropped(image)
        for size in [16, 32, 128, 256, 512] {
            for (suffix, px) in [("", size), ("@2x", size * 2)] {
                let scaledImage = scaled(square, maxDimension: px)
                try write(scaledImage, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), format: Catalog.png)
            }
        }
        try runProcess("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", url.path])
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Conversion

    static func convert(_ url: URL, to target: Format) throws -> URL {
        let out = OutputPaths.output(for: url, ext: target.ext)
        if canEncode(target) {
            try write(try load(url), to: out, format: target)
            return out
        }
        // Formats without a native encoder go through cwebp or ffmpeg.
        var input = url
        if !["png", "jpg", "jpeg", "bmp", "tiff", "tif", "gif", "webp"].contains(url.pathExtension.lowercased()) {
            let tmp = try OutputPaths.temporaryDirectory().appendingPathComponent("in.png")
            try write(try load(url), to: tmp, format: Catalog.png)
            input = tmp
        }
        if target.id == "webp", let cwebp = Backends.path(for: .cwebp) {
            var src = input
            if !["png", "jpg", "jpeg", "tiff", "tif", "webp"].contains(src.pathExtension.lowercased()) {
                src = try OutputPaths.temporaryDirectory().appendingPathComponent("in.png")
                try write(try load(url), to: src, format: Catalog.png)
            }
            try runProcess(cwebp, ["-quiet", "-q", "85", "-metadata", "none", src.path, "-o", out.path])
            return out
        }
        guard let ffmpeg = Backends.path(for: .ffmpeg) else { throw MissingBackendError(backend: target.id == "webp" ? .cwebp : .ffmpeg) }
        let codec: [String]
        switch target.id {
        case "webp": codec = ["-c:v", "libwebp", "-quality", "85"]
        case "avif": codec = ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "30"]
        case "tga": codec = ["-c:v", "targa"]
        default: codec = []
        }
        try runProcess(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path] + codec + [out.path])
        return out
    }

    // MARK: Editing primitives

    static func context(width: Int, height: Int, gray: Bool = false) -> CGContext? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        ctx?.interpolationQuality = .high
        return ctx
    }

    static func flattened(_ image: CGImage, background: NSColor = .white) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height) else { return image }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        guard let ctx = context(width: Int(size.width.rounded()), height: Int(size.height.rounded())) else { return image }
        ctx.draw(image, in: CGRect(origin: .zero, size: CGSize(width: ctx.width, height: ctx.height)))
        return ctx.makeImage() ?? image
    }

    static func scaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let factor = min(1, CGFloat(maxDimension) / max(w, h))
        if factor == 1 { return image }
        return scaled(image, to: CGSize(width: (w * factor).rounded(), height: (h * factor).rounded()))
    }

    static func scaled(_ image: CGImage, factor: CGFloat) -> CGImage {
        scaled(image, to: CGSize(width: (CGFloat(image.width) * factor).rounded(), height: (CGFloat(image.height) * factor).rounded()))
    }

    static func rotated90(_ image: CGImage) -> CGImage {
        guard let ctx = context(width: image.height, height: image.width) else { return image }
        ctx.translateBy(x: CGFloat(image.height), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func flippedHorizontally(_ image: CGImage) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height) else { return image }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func grayscale(_ image: CGImage) -> CGImage {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPhotoEffectMono") else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return image }
        return cg
    }

    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage {
        image.cropping(to: rect.integral) ?? image
    }

    static func squareCropped(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        return cropped(image, to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
    }

    /// Center crop to an aspect ratio (width / height).
    static func cropped(_ image: CGImage, aspect: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        return cropped(image, to: CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch))
    }

    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { throw OrbitError("No foreground subject found.") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw OrbitError("Could not build masked image.") }
        return cg
    }

    /// Re-encodes to a smaller file; keeps format unless the source has no alpha and is PNG/TIFF/BMP (then JPEG).
    static func compressed(_ url: URL) throws -> URL {
        let image = try load(url)
        let source = Catalog.format(for: url) ?? Catalog.jpg
        let target: Format
        switch source.id {
        case "png", "tiff", "bmp", "tga": target = image.hasAlpha ? Catalog.png : Catalog.jpg
        case "heic", "webp", "avif", "jpg": target = source
        default: target = Catalog.jpg
        }
        let out = OutputPaths.output(for: url, ext: target.ext, suffix: "compressed")
        var working = image
        if max(image.width, image.height) > 4096 { working = scaled(image, maxDimension: 4096) }
        try write(working, to: out, format: target, quality: target.id == "png" ? nil : 0.62)
        let before = fileSize(url), after = fileSize(out)
        if after >= before, target.id == source.id {
            try? FileManager.default.removeItem(at: out)
            throw OrbitError("\(url.lastPathComponent) is already as small as it gets.")
        }
        return out
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
