// Generates Resources/AppIcon.icns (a crescent moon with "z" marks on a night-sky tile).
// Usage: swift scripts/make_icon.swift <output-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetPath = (outputDir as NSString).appendingPathComponent("AppIcon.iconset")
let fileManager = FileManager.default
try? fileManager.removeItem(atPath: iconsetPath)
try fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create bitmap context")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels)

    // Night-sky tile.
    let inset = s * 0.06
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.34, green: 0.25, blue: 0.68, alpha: 1)
    ])?.draw(in: tilePath, angle: -60)

    // Crescent = big circle minus an offset circle.
    let cg = context.cgContext
    let radius = s * 0.27
    let center = CGPoint(x: s * 0.45, y: s * 0.50)
    let moon = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    let cutRadius = radius * 0.86
    let cutCenter = CGPoint(x: center.x + radius * 0.50, y: center.y + radius * 0.28)
    let cut = CGPath(ellipseIn: CGRect(x: cutCenter.x - cutRadius, y: cutCenter.y - cutRadius, width: cutRadius * 2, height: cutRadius * 2), transform: nil)
    cg.addPath(moon.subtracting(cut))
    cg.setFillColor(NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.70, alpha: 1).cgColor)
    cg.fillPath()

    // Three "z" marks, growing toward the upper right.
    let marks: [(String, CGFloat, CGPoint)] = [
        ("z", 0.10, CGPoint(x: 0.66, y: 0.40)),
        ("z", 0.14, CGPoint(x: 0.72, y: 0.52)),
        ("Z", 0.19, CGPoint(x: 0.76, y: 0.66))
    ]
    for (text, scale, position) in marks {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: s * scale, weight: .heavy),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92)
        ]
        NSString(string: text).draw(at: NSPoint(x: s * position.x, y: s * position.y), withAttributes: attributes)
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    return png
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, pixels) in variants {
    try render(pixels: pixels).write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent("\(name).png"))
}
print("Wrote \(iconsetPath)")
