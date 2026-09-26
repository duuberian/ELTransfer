import AppKit

// Explicit 1× + 2× bitmap representations keep Finder sharp on every display.
let size = NSSize(width: 820, height: 660)
let image = NSImage(size: size)
let paper = NSColor(red: 1.0, green: 0.94, blue: 0.875, alpha: 1)
let ink = NSColor(red: 0.18, green: 0.15, blue: 0.145, alpha: 1)
let blue = NSColor(red: 0.18, green: 0.43, blue: 0.55, alpha: 1)
for scale in [1, 2] {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 820 * scale,
    pixelsHigh: 660 * scale, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  paper.setFill()
  NSRect(origin: .zero, size: size).fill()
  ink.withAlphaComponent(0.12).setFill()
  for x in stride(from: 18.0, to: 820, by: 24) {
    for y in stride(from: 18.0, to: 660, by: 24) {
      NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1, height: 1)).fill()
    }
  }
  // Reserve room for Finder's tab/path bars without clipping the setup guide.
  let layoutOffset = NSAffineTransform()
  layoutOffset.translateX(by: 0, yBy: 100)
  layoutOffset.concat()
  func text(_ value: String, y: CGFloat, size: CGFloat, handwritten: Bool = false) {
    let font = handwritten ? NSFont(name: "Bradley Hand", size: size) ?? .systemFont(ofSize: size) : .systemFont(ofSize: size, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let width = (value as NSString).size(withAttributes: attributes).width
    (value as NSString).draw(at: NSPoint(x: (820 - width) / 2, y: y), withAttributes: attributes)
  }
  text("Welcome to ELTransfer.", y: 477, size: 34)
  text("Two Macs. One pointer.", y: 434, size: 25, handwritten: true)
  blue.setStroke()
  let arrow = NSBezierPath()
  arrow.lineWidth = 3
  arrow.lineCapStyle = .round
  arrow.move(to: NSPoint(x: 320, y: 308))
  arrow.curve(to: NSPoint(x: 494, y: 308), controlPoint1: NSPoint(x: 375, y: 340), controlPoint2: NSPoint(x: 442, y: 280))
  arrow.move(to: NSPoint(x: 479, y: 324))
  arrow.line(to: NSPoint(x: 497, y: 308))
  arrow.line(to: NSPoint(x: 476, y: 297))
  arrow.stroke()
  text("drag me over", y: 351, size: 23, handwritten: true)
  text("1. Drag ELTransfer into Applications, on both Macs.", y: 178, size: 23)
  text("2. Open it. A small ↔ appears in the menu bar.", y: 140, size: 23)
  text("3. Hold ⌘ on both, then nudge a screen edge.", y: 102, size: 20)
  text("Privacy & Security → Accessibility + Input Monitoring", y: 53, size: 19, handwritten: true)
  NSGraphicsContext.restoreGraphicsState()
  image.addRepresentation(bitmap)
}
guard CommandLine.arguments.count == 2, let tiff = image.tiffRepresentation else {
  fatalError("Usage: swift dmg-background.swift output.tiff")
}
try tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
