// The README's hero: the app window, the menu bar panel and the dictation pill
// together on a quiet backdrop — once for light mode, once for dark.
//
//   swift scripts/screenshots/hero.swift docs/images/en
//
// Reads meeting-<mode>.png (the window's content, as `--render-window` draws it) and
// panel-<mode>.png (`--render-panel --clear`), both 2x, and writes hero-<mode>.png. The
// window gets its rounded corners and shadow here.

import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func load(_ name: String) -> CGImage? {
    guard let image = NSImage(contentsOf: dir.appendingPathComponent(name)) else { return nil }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

for mode in ["light", "dark"] {
    guard let window = load("meeting-\(mode).png"), let panel = load("panel-\(mode).png") else {
        print("✗ hero-\(mode): missing captures"); continue
    }
    let dark = mode == "dark"
    // Canvas in pixels (captures are 2x): room around the window, the panel overhanging to the right.
    let width = CGFloat(window.width) + 560, height = CGFloat(window.height) + 250
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Backdrop: a soft vertical wash with a faint glow behind the window.
    let top = dark ? CGColor(gray: 0.10, alpha: 1) : CGColor(gray: 0.985, alpha: 1)
    let bottom = dark ? CGColor(gray: 0.03, alpha: 1) : CGColor(gray: 0.90, alpha: 1)
    let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(gray: dark ? 1 : 1, alpha: dark ? 0.07 : 0.7), CGColor(gray: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: width * 0.42, y: height * 0.55), startRadius: 0,
                           endCenter: CGPoint(x: width * 0.42, y: height * 0.55), endRadius: width * 0.55, options: [])

    // Window left of centre with its corners and shadow, the panel overlapping its top-right corner.
    let windowOrigin = CGPoint(x: 120, y: 150)
    let frame = CGRect(origin: windowOrigin, size: CGSize(width: window.width, height: window.height))
    let shape = CGPath(roundedRect: frame, cornerWidth: 52, cornerHeight: 52, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 90, color: CGColor(gray: 0, alpha: dark ? 0.7 : 0.28))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: dark ? 0.1 : 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(window, in: frame)
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: 0.12)); ctx.setLineWidth(2); ctx.strokePath()
    let panelOrigin = CGPoint(x: width - CGFloat(panel.width) - 70, y: height - CGFloat(panel.height) - 40)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 60, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.25))
    ctx.draw(panel, in: CGRect(origin: panelOrigin, size: CGSize(width: panel.width, height: panel.height)))
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let out = dir.appendingPathComponent("hero-\(mode).png")
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    print("✓ hero-\(mode)")
}
