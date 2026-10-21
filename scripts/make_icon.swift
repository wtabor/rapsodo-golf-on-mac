// Turn a square app image into a macOS-style icon master: 1024x1024 canvas with the
// art on an 824 pt rounded tile (Apple's icon grid), transparent around it.
// Usage: swift make_icon.swift <in.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make_icon.swift <in.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let size = 1024, tile = 824.0, inset = (1024.0 - 824.0) / 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let rect = NSRect(x: inset, y: inset, width: tile, height: tile)
NSBezierPath(roundedRect: rect, xRadius: tile * 0.225, yRadius: tile * 0.225).addClip()
src.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
