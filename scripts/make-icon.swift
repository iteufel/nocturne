import AppKit
import Foundation

func drawIcon(size: Int) -> Data {
    // An explicit RGB bitmap keeps the App Store icon opaque and pixel-exact,
    // independently of the build machine's display scale or WindowServer.
    let context = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let s = CGFloat(size)
    NSColor(red: 0.055, green: 0.07, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()
    let circle = NSBezierPath(ovalIn: NSRect(x: s * 0.22, y: s * 0.22, width: s * 0.56, height: s * 0.56))
    NSGradient(colors: [NSColor(red: 0.94, green: 0.96, blue: 1, alpha: 1), NSColor(red: 0.48, green: 0.60, blue: 0.9, alpha: 1)])!.draw(in: circle, angle: -50)
    NSColor(red: 0.055, green: 0.07, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.39, y: s * 0.36, width: s * 0.48, height: s * 0.48)).fill()
    NSColor(red: 0.72, green: 0.8, blue: 1, alpha: 0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.69, y: s * 0.25, width: s * 0.032, height: s * 0.032)).fill()
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    precondition(!rep.hasAlpha)
    return rep.representation(using: .png, properties: [:])!
}
let fm = FileManager.default
for (folder, name, mac) in [("Client", "DarkAppIcon", false), ("Server", "ServerAppIcon", true)] {
    let root = "Resources/\(folder).xcassets"
    let path = root + "/\(name).appiconset"
    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: URL(fileURLWithPath: root + "/Contents.json"))
    var images: [[String: String]] = []
    if mac {
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let filename = "icon-\(size)-\(scale).png"
                try drawIcon(size: size * scale).write(to: URL(fileURLWithPath: path + "/" + filename))
                images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":filename])
            }
        }
    } else {
        try drawIcon(size: 1024).write(to: URL(fileURLWithPath: path + "/icon.png"))
        images = [["idiom":"universal", "platform":"ios", "size":"1024x1024", "filename":"icon.png"]]
    }
    let json: [String: Any] = ["images":images, "info":["author":"xcode", "version":1]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path + "/Contents.json"))
}
