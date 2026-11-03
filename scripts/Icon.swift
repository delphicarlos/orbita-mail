import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let n = CGFloat(pixels)
        let bounds = NSRect(x: n * 0.05, y: n * 0.05, width: n * 0.9, height: n * 0.9)
        NSColor(srgbRed: 0.70, green: 0.20, blue: 0.39, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: n * 0.20, yRadius: n * 0.20).fill()
        if let symbol = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: n * 0.48, weight: .medium)) {
            let rect = NSRect(x: n * 0.23, y: n * 0.27, width: n * 0.54, height: n * 0.44)
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill(); NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: rect)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try png.write(to: directory.appendingPathComponent(filename))
    }
}
