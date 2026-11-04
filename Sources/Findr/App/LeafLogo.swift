import AppKit

/// Shared vector artwork for the app icon and the system-tinted menu-bar template.
enum LeafLogo {
    static func image(size: CGFloat, appIcon: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 1000)
            transform.concat()
            if appIcon {
                NSColor(srgbRed: 247/255, green: 244/255, blue: 235/255, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 900, height: 900),
                             xRadius: 200, yRadius: 200).fill()
                let inset = NSAffineTransform()
                inset.translateX(by: 110, yBy: 100)
                inset.scale(by: 0.78)
                inset.concat()
            }
            NSColor(srgbRed: 40/255, green: 51/255, blue: 45/255, alpha: 1).setFill()
            let rear = NSBezierPath()
            rear.move(to: NSPoint(x: 220, y: 310))
            rear.curve(to: NSPoint(x: 145, y: 390), controlPoint1: NSPoint(x: 175, y: 310), controlPoint2: NSPoint(x: 145, y: 340))
            rear.line(to: NSPoint(x: 145, y: 720))
            rear.curve(to: NSPoint(x: 245, y: 820), controlPoint1: NSPoint(x: 145, y: 780), controlPoint2: NSPoint(x: 180, y: 815))
            rear.curve(to: NSPoint(x: 220, y: 740), controlPoint1: NSPoint(x: 225, y: 790), controlPoint2: NSPoint(x: 220, y: 770))
            rear.close()
            rear.fill()

            let page = NSBezierPath()
            page.move(to: NSPoint(x: 270, y: 300))
            page.curve(to: NSPoint(x: 350, y: 210), controlPoint1: NSPoint(x: 270, y: 250), controlPoint2: NSPoint(x: 285, y: 225))
            page.line(to: NSPoint(x: 680, y: 150))
            page.curve(to: NSPoint(x: 750, y: 215), controlPoint1: NSPoint(x: 725, y: 140), controlPoint2: NSPoint(x: 750, y: 170))
            page.line(to: NSPoint(x: 750, y: 285))
            page.curve(to: NSPoint(x: 305, y: 740), controlPoint1: NSPoint(x: 430, y: 310), controlPoint2: NSPoint(x: 310, y: 470))
            page.line(to: NSPoint(x: 305, y: 820))
            page.curve(to: NSPoint(x: 270, y: 740), controlPoint1: NSPoint(x: 280, y: 800), controlPoint2: NSPoint(x: 270, y: 775))
            page.close()
            page.fill()

            let leaf = NSBezierPath()
            leaf.windingRule = .evenOdd
            leaf.move(to: NSPoint(x: 330, y: 835))
            leaf.curve(to: NSPoint(x: 850, y: 295), controlPoint1: NSPoint(x: 350, y: 410), controlPoint2: NSPoint(x: 575, y: 350))
            leaf.curve(to: NSPoint(x: 660, y: 740), controlPoint1: NSPoint(x: 840, y: 510), controlPoint2: NSPoint(x: 800, y: 650))
            leaf.curve(to: NSPoint(x: 330, y: 835), controlPoint1: NSPoint(x: 560, y: 790), controlPoint2: NSPoint(x: 440, y: 785))
            leaf.close()
            leaf.move(to: NSPoint(x: 330, y: 835))
            leaf.curve(to: NSPoint(x: 770, y: 385), controlPoint1: NSPoint(x: 450, y: 535), controlPoint2: NSPoint(x: 650, y: 445))
            leaf.curve(to: NSPoint(x: 330, y: 835), controlPoint1: NSPoint(x: 590, y: 510), controlPoint2: NSPoint(x: 450, y: 670))
            leaf.close()
            leaf.fill()
            return true
        }
        image.accessibilityDescription = "Leaf"
        image.isTemplate = !appIcon
        return image
    }
}
