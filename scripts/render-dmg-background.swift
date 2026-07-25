#!/usr/bin/env swift

import AppKit

private let canvasSize = NSSize(width: 660, height: 400)

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-dmg-background.swift <source.png> <output.png>\n", stderr)
    exit(64)
}

guard let sourceImage = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Unable to load the DMG background source image.\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Unable to create the DMG background bitmap.\n", stderr)
    exit(1)
}

bitmap.size = canvasSize
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create a graphics context for the DMG background.\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context

let sourceAspectRatio = sourceImage.size.width / sourceImage.size.height
let destinationAspectRatio = canvasSize.width / canvasSize.height
let sourceRect: NSRect
if sourceAspectRatio < destinationAspectRatio {
    let croppedHeight = sourceImage.size.width / destinationAspectRatio
    sourceRect = NSRect(
        x: 0,
        y: (sourceImage.size.height - croppedHeight) / 2,
        width: sourceImage.size.width,
        height: croppedHeight
    )
} else {
    let croppedWidth = sourceImage.size.height * destinationAspectRatio
    sourceRect = NSRect(
        x: (sourceImage.size.width - croppedWidth) / 2,
        y: 0,
        width: croppedWidth,
        height: sourceImage.size.height
    )
}
sourceImage.draw(
    in: NSRect(origin: .zero, size: canvasSize),
    from: sourceRect,
    operation: .copy,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)

NSColor.black.withAlphaComponent(0.08).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

func drawText(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    text.draw(
        in: NSRect(x: x, y: y, width: canvasSize.width - x - 40, height: font.pointSize + 10),
        withAttributes: attributes
    )
}

drawText(
    "FindDiskKiller",
    x: 42,
    y: 333,
    font: .systemFont(ofSize: 23, weight: .semibold),
    color: NSColor.white.withAlphaComponent(0.96)
)
drawText(
    "Drag the app to Applications",
    x: 43,
    y: 305,
    font: .systemFont(ofSize: 13, weight: .regular),
    color: NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.78, alpha: 1)
)

guard let chevron = NSImage(
    systemSymbolName: "chevron.right",
    accessibilityDescription: "Drag to Applications"
)?.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
) else {
    fputs("Unable to create the DMG direction symbol.\n", stderr)
    exit(1)
}

let chevronColors: [(CGFloat, NSColor)] = [
    (306, NSColor(calibratedRed: 0.36, green: 0.75, blue: 0.86, alpha: 0.28)),
    (326, NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.80, alpha: 0.55)),
    (346, NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.70, alpha: 0.90))
]
for (x, color) in chevronColors {
    guard let coloredChevron = chevron.withSymbolConfiguration(
        NSImage.SymbolConfiguration(hierarchicalColor: color)
    ) else { continue }
    coloredChevron.draw(
        in: NSRect(x: x, y: 155, width: 18, height: 20),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
}

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode the DMG background as PNG.\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
} catch {
    fputs("Unable to write the DMG background: \(error)\n", stderr)
    exit(1)
}
