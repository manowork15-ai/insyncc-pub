// Renders the 1024×1024 app icon PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centred on a 1024 canvas.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 1.00, green: 0.42, blue: 0.30, alpha: 1),
                    NSColor(red: 0.89, green: 0.13, blue: 0.33, alpha: 1)])!
    .draw(in: shape, angle: -60)

// Lens ring + record dot
let ring = NSBezierPath(ovalIn: NSRect(x: 312, y: 312, width: 400, height: 400))
ring.lineWidth = 44
NSColor.white.setStroke()
ring.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 412, y: 412, width: 200, height: 200)).fill()

// Small "page" mark top-right to hint at a diary
let tab = NSBezierPath(roundedRect: NSRect(x: 650, y: 690, width: 110, height: 40), xRadius: 20, yRadius: 20)
NSColor.white.withAlphaComponent(0.85).setFill()
tab.fill()

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: out)
