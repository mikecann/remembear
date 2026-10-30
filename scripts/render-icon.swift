// Renders icons/remembear.svg to icons/remembear.png at 1024 px, using AppKit's
// own SVG support so there's nothing to install.
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]) else { fatalError("usage: render-icon in.svg out.png") }
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
