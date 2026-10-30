import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { rect in
    NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()
    let card = NSBezierPath(roundedRect: rect.insetBy(dx: 150, dy: 120), xRadius: 72, yRadius: 72)
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.24, alpha: 1).setFill()
    card.fill()
    NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
    for (index, width) in [520, 430, 470, 360].enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 250, y: 690 - CGFloat(index) * 90, width: CGFloat(width), height: 36), xRadius: 8, yRadius: 8)
        bar.fill()
    }
    let mark = NSBezierPath(roundedRect: NSRect(x: 620, y: 250, width: 150, height: 150), xRadius: 36, yRadius: 36)
    NSColor(srgbRed: 0.76, green: 0.32, blue: 0.16, alpha: 1).setFill()
    mark.fill()
    return true
}
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法生成图标\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
