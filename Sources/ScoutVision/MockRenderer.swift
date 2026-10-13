import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import ScoutCore

public enum MockScene: String, CaseIterable, Codable, Sendable {
    case ready = "Ready"
    case animation = "Transition"
    case purple = "Purple bonus"
    case green = "Green bonus"
    case red = "Red bonus (synthetic)"
    case zero = "Zero spins remaining"
    case results = "Results"
    case unknown = "Unknown bonus entry"
    case blocked = "Connection error"
    case colourOnly = "Colour only"
    public var expected: ScreenState {
        switch self {
        case .ready: return .ready
        case .animation: return .animation
        case .purple, .green, .red, .zero: return .bonus
        case .results: return .results
        default: return .unknown
        }
    }
}

public enum MockRenderer {
    public static func image(scene: MockScene, scale: Double = 1, variant: Int = 0) -> CGImage {
        let width = 960, height = 640
        let c = CGContext(data: nil, width: Int(Double(width) * scale), height: Int(Double(height) * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        let background: (CGFloat, CGFloat, CGFloat)
        switch scene {
        case .purple: background = (0.38, 0.15, 0.55)
        case .green, .zero: background = (0.14, 0.48, 0.20)
        case .red: background = (0.65, 0.15, 0.16)
        case .results: background = (0.15, 0.18, 0.30)
        case .unknown, .blocked: background = (0.19, 0.23, 0.3)
        default: background = (0.06, 0.52, 0.56)
        }
        c.setFillColor(CGColor(red: background.0, green: background.1, blue: background.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ string: String, y: CGFloat, size: CGFloat = 32, color: CGColor = CGColor(gray: 1, alpha: 1)) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attr = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            let line = CTLineCreateWithAttributedString(attr)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            c.saveGState(); c.translateBy(x: (960 - w) / 2, y: y + size); c.scaleBy(x: 1, y: -1)
            c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
        }
        text("SCREEN SCOUT  /  LOCAL MOCK", y: 24, size: 20)
        if scene == .results {
            text("CONGRATULATIONS!", y: 120, size: 48)
            text("YOU HAVE WON", y: 212, size: 30)
            text(variant == 0 ? "123.45" : "8,765.00", y: 280, size: 60)
            text("IN \(variant == 0 ? 9 : 12) FREE SPINS", y: 385, size: 32)
            text("PRESS ANYWHERE TO CONTINUE", y: 525, size: 30)
        } else if scene == .unknown {
            text("CHOOSE A MYSTERY POT", y: 240, size: 44)
            text("BONUS ENTRY EXAMPLE", y: 360, size: 24)
        } else if scene == .blocked {
            text("CONNECTION ERROR", y: 250, size: 42)
            text("PLEASE RECONNECT", y: 340, size: 24)
        } else if scene == .colourOnly {
            text("A STILL TURQUOISE SCREEN", y: 260, size: 36)
        } else {
            for column in 0..<3 {
                let x = 135 + column * 190
                c.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.82, alpha: 1))
                c.fill(CGRect(x: x, y: 150, width: 170, height: 290))
                c.setStrokeColor(CGColor(gray: 0.08, alpha: 1)); c.setLineWidth(5)
                c.stroke(CGRect(x: x, y: 150, width: 170, height: 290))
                for row in 0..<3 {
                    c.setFillColor(CGColor(red: 0.3 + CGFloat(column) * 0.12, green: 0.3 + CGFloat(row) * 0.10, blue: 0.55, alpha: 1))
                    c.fillEllipse(in: CGRect(x: x + 55 + variant % 5, y: 180 + row * 85, width: 58, height: 54))
                }
            }
            c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setLineWidth(9)
            c.strokeEllipse(in: CGRect(x: 777, y: 387, width: 106, height: 106))
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.beginPath(); c.move(to: CGPoint(x: 818, y: 418)); c.addLine(to: CGPoint(x: 847, y: 440)); c.addLine(to: CGPoint(x: 818, y: 462)); c.closePath(); c.fillPath()
            switch scene {
            case .ready: text("PLACE YOUR BETS!", y: 554, size: 34)
            case .animation: text("DEMO TRANSITION", y: 554, size: 34)
            case .purple: text("5 FREE SPINS LEFT", y: 554, size: 34)
            case .green: text("2 FREE SPINS LEFT", y: 554, size: 34)
            case .red: text("4 FREE SPINS LEFT", y: 554, size: 34)
            case .zero: text("0 FREE SPINS LEFT", y: 554, size: 34)
            default: break
            }
        }
        return c.makeImage()!
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ScreenScout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG file."])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ScreenScout", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG write failed."]) }
    }
}
