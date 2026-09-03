import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let output = root.appendingPathComponent("Sources/CloudCodeApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create graphics context")
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(calibratedRed: 0.20, green: 0.75, blue: 0.93, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.95, alpha: 1).cgColor
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 1024),
    end: CGPoint(x: 1024, y: 0),
    options: []
)

context.setFillColor(NSColor.white.cgColor)
context.fillEllipse(in: CGRect(x: 240, y: 350, width: 320, height: 320))
context.fillEllipse(in: CGRect(x: 390, y: 300, width: 350, height: 350))
context.fillEllipse(in: CGRect(x: 575, y: 360, width: 245, height: 285))
let cloudBase = CGPath(roundedRect: CGRect(x: 225, y: 315, width: 600, height: 220), cornerWidth: 105, cornerHeight: 105, transform: nil)
context.addPath(cloudBase)
context.fillPath()

context.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.95, alpha: 1).cgColor)
context.setLineWidth(42)
context.setLineCap(.round)
context.setLineJoin(.round)

func stroke(_ points: [CGPoint]) {
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}

stroke([CGPoint(x: 405, y: 485), CGPoint(x: 330, y: 415), CGPoint(x: 405, y: 345)])
stroke([CGPoint(x: 535, y: 520), CGPoint(x: 470, y: 315)])
stroke([CGPoint(x: 610, y: 485), CGPoint(x: 685, y: 415), CGPoint(x: 610, y: 345)])

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [.compressionFactor: 0.95]) else {
    fatalError("Unable to encode app icon")
}
try png.write(to: output, options: .atomic)
print("Materialized app icon: \(output.path) (\(png.count) bytes)")
