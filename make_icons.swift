#!/usr/bin/swift

import Cocoa
import CoreText
import CoreGraphics

func renderIcon(pixelSize: Int, text: String, withBox: Bool = true) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let size = CGFloat(pixelSize)

    if withBox {
        // Rounded rect background with blue gradient
        let radius = size * 0.225
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 0, y: 0, width: size, height: size),
                            cornerWidth: radius, cornerHeight: radius)
        ctx.addPath(path)
        ctx.clip()

        let colors = [
            CGColor(colorSpace: cs, components: [0.35, 0.55, 0.95, 1.0])!,
            CGColor(colorSpace: cs, components: [0.20, 0.35, 0.85, 1.0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        // angle -60 degrees: top-left → bottom-right
        let angle = CGFloat(-60) * .pi / 180
        let dx = cos(angle) * size * 0.5
        let dy = sin(angle) * size * 0.5
        let cx = size / 2, cy = size / 2
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: cx - dx, y: cy - dy),
            end: CGPoint(x: cx + dx, y: cy + dy),
            options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        ctx.resetClip()
    }

    // Draw text using Core Text
    let fontSize = size * 0.62
    let font = CTFontCreateWithName("HiraginoSans-W4" as CFString, fontSize, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: withBox
            ? CGColor(colorSpace: cs, components: [1, 1, 1, 1])!
            : CGColor(colorSpace: cs, components: [0, 0, 0, 1])!
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrStr)

    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let textHeight = ascent + descent

    let x = (size - CGFloat(width)) / 2
    let y = (size - textHeight) / 2 + descent + size * 0.02

    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)

    return ctx.makeImage()!
}

func saveImage(_ image: CGImage, to path: String, dpi: CGFloat = 72) {
    let url = URL(fileURLWithPath: path) as CFURL
    let uti = path.hasSuffix(".tiff") ? "public.tiff" : "public.png"
    guard let dest = CGImageDestinationCreateWithURL(url, uti as CFString, 1, nil) else { return }
    let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(dest, image, props)
    CGImageDestinationFinalize(dest)
    print("  \(path)")
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."

// App icon sizes
let appSizes = [16, 32, 64, 128, 256, 512, 1024]
for size in appSizes {
    saveImage(renderIcon(pixelSize: size, text: "あ"), to: "\(outDir)/app_\(size).png")
}

// Input source icon: template (black on transparent), TISIconIsTemplate=true lets macOS add the box
// Use @2x naming convention (macOS auto-picks the right resolution)
saveImage(renderIcon(pixelSize: 32, text: "あ", withBox: false), to: "\(outDir)/InputSource.tiff", dpi: 72)
saveImage(renderIcon(pixelSize: 64, text: "あ", withBox: false), to: "\(outDir)/InputSource@2x.tiff", dpi: 144)

print("Done.")
