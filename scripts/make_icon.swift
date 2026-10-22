// Draws the Orbit app icon (a radial wheel around a hub) as a 1024px PNG.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let c = CGPoint(x: size / 2, y: size / 2)
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 60, dy: 60), xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.16, alpha: 1),
                                       NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
    gradient.draw(in: bg, angle: -90)
    let segments = 8
    for i in 0..<segments {
        let a0 = CGFloat(i) * 360 / CGFloat(segments) + 3, a1 = CGFloat(i + 1) * 360 / CGFloat(segments) - 3
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: 400, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
        p.appendArc(withCenter: c, radius: 215, startAngle: 90 - a1, endAngle: 90 - a0, clockwise: false)
        p.close()
        (i == 1 ? NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 1)
                : NSColor(calibratedWhite: 0.22 + CGFloat(i % 2) * 0.05, alpha: 1)).setFill()
        p.fill()
    }
    _ = ctx
    let hub = NSBezierPath(ovalIn: NSRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300))
    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 1).setFill()
    hub.fill()
    let inner = NSBezierPath(ovalIn: NSRect(x: c.x - 70, y: c.y - 70, width: 140, height: 140))
    NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
    inner.fill()
    return true
}
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
