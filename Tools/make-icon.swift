// Draws the app icon: a white heart with a pulse trace on a red gradient tile.
// Usage: swift Tools/make-icon.swift  (writes App/BPTracker/Assets.xcassets/AppIcon.appiconset)
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824-point tile centred on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(red: 0.85, green: 0.15, blue: 0.27, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1),
                                       CGColor(red: 0.80, green: 0.10, blue: 0.29, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Heart: the classic parametric curve x = 16 sin³t, y = 13 cos t − 5 cos 2t − 2 cos 3t − cos 4t.
    let heart = CGMutablePath()
    let scale: CGFloat = 17, center = CGPoint(x: 512, y: 565)
    for step in 0...360 {
        let t = Double(step) * .pi / 180
        let x = 16 * pow(sin(t), 3)
        let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
        let point = CGPoint(x: center.x + CGFloat(x) * scale, y: center.y + CGFloat(y) * scale)
        if step == 0 { heart.move(to: point) } else { heart.addLine(to: point) }
    }
    heart.closeSubpath()
    ctx.addPath(heart)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()

    // Pulse trace across the heart.
    let trace = CGMutablePath()
    let y: CGFloat = 575
    trace.move(to: CGPoint(x: 190, y: y))
    trace.addLine(to: CGPoint(x: 375, y: y))
    trace.addLine(to: CGPoint(x: 425, y: y + 95))
    trace.addLine(to: CGPoint(x: 490, y: y - 150))
    trace.addLine(to: CGPoint(x: 555, y: y + 170))
    trace.addLine(to: CGPoint(x: 610, y: y))
    trace.addLine(to: CGPoint(x: 834, y: y))
    ctx.addPath(trace)
    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.13, blue: 0.29, alpha: 1))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = here.appending(path: "../App/BPTracker/Assets.xcassets/AppIcon.appiconset").standardizedFileURL
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(size: points * scale).write(to: set.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appending(path: "Contents.json"))
let catalog = set.deletingLastPathComponent().appending(path: "Contents.json")
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(to: catalog, atomically: true, encoding: .utf8)
print("wrote \(set.path)")
