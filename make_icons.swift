#!/usr/bin/swift

import Cocoa

func renderIcon(size: Int, text: String, template: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    if !template {
        // App icon: rounded rect background with gradient
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let radius = CGFloat(size) * 0.225
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let gradient = NSGradient(
            colors: [
                NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1),
                NSColor(red: 0.20, green: 0.35, blue: 0.85, alpha: 1)
            ],
            atLocations: [0, 1],
            colorSpace: .sRGB
        )!
        gradient.draw(in: path, angle: -60)
    }

    let fontSize = CGFloat(size) * (template ? 0.80 : 0.62)
    let font = NSFont.systemFont(ofSize: fontSize, weight: template ? .regular : .medium)
    let color = template ? NSColor.black : NSColor.white
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]

    let str = text as NSString
    let textSize = str.size(withAttributes: attrs)
    let x = (CGFloat(size) - textSize.width) / 2
    let y = (CGFloat(size) - textSize.height) / 2 + (template ? 0 : CGFloat(size) * 0.02)
    str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return }
    try! png.write(to: URL(fileURLWithPath: path))
    print("  \(path)")
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."

// App icon sizes
let appSizes = [16, 32, 64, 128, 256, 512, 1024]
for size in appSizes {
    let img = renderIcon(size: size, text: "あ")
    savePNG(img, to: "\(outDir)/app_\(size).png")
}

// Input source icon (template: black on transparent)
for size in [16, 32, 64] {
    let img = renderIcon(size: size, text: "あ", template: true)
    savePNG(img, to: "\(outDir)/input_\(size).png")
}

print("Done.")
