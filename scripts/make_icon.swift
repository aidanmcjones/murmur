import AppKit
// Renders Murmur's app icon (waveform on a rounded gradient square) to a 1024px PNG.
let out = CommandLine.arguments[1]
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: s - 200, height: s - 200)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.95, alpha: 1))!.draw(in: path, angle: -60)
let cfg = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let r = NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2, width: sym.size.width, height: sym.size.height)
    sym.draw(in: r)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
