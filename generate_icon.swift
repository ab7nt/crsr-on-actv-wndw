import Cocoa

// Create a 1024x1024 icon
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

// Draw background (White Squircle)
let rect = NSRect(origin: .zero, size: size)
// Standard macOS icon shape is roughly a rounded rect with specialized curvature, but standard rounded rect is close enough for custom icons.
let path = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
NSColor.white.setFill()
path.fill()

// Draw a simple Lock symbol (Just the lock, no circle container)
// We use "lock.fill" so it's solid.
let symbolScale: CGFloat = 0.65
let symbolSize = size.width * symbolScale

if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
    // Configure it to be dark gray/black
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(white: 0.15, alpha: 1.0)])) // Dark Gray (looks better than pure black on white)
    
    if let fittedSymbol = symbol.withSymbolConfiguration(config) {
        // Center it
        let layoutRect = NSRect(
            x: (size.width - fittedSymbol.size.width) / 2,
            y: (size.height - fittedSymbol.size.height) / 2,
            width: fittedSymbol.size.width,
            height: fittedSymbol.size.height
        )
        fittedSymbol.draw(in: layoutRect)
    }
}

image.unlockFocus()

// Save to disk
if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
    if let png = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: "Assets/icon.png")
        try? png.write(to: url)
    }
}
