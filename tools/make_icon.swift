// Рисует иконку приложения (снежинка на голубом градиенте) и собирает Resources/AppIcon.icns.
// Запуск: swiftc tools/make_icon.swift -o /tmp/mkicon && /tmp/mkicon
import AppKit

let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Отступ и скругление как у стандартных иконок macOS.
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1),
                        NSColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: 90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.45, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let sz = sym.size
    sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Resources/AppIcon.icns")
