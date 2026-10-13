import Foundation
import CoreGraphics
import Vision
import ScoutCore

public enum ImageAnalyzer {
    public static func analyze(_ image: CGImage, id: UInt64, capturedAt: TimeInterval) throws -> Observation {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 24
        rectangles.minimumConfidence = 0.65
        rectangles.minimumSize = 0.1
        rectangles.minimumAspectRatio = 0.25
        rectangles.maximumAspectRatio = 0.95
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request, rectangles])
        let text = (request.results ?? []).compactMap { observation -> TextEvidence? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return TextEvidence(candidate.string, confidence: Double(candidate.confidence), bounds: .init(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        var features = visualFeatures(image)
        let candidates = (rectangles.results ?? []).map(\.boundingBox).filter {
            $0.width > 0.10 && $0.width < 0.28 && $0.height > 0.25 && $0.height < 0.65 && $0.minX > 0.04 && $0.maxX < 0.81
        }.sorted { $0.minX < $1.minX }
        // Count separate, vertically aligned columns; nested outlines count only once.
        var columns: [CGRect] = []
        for candidate in candidates {
            if let last = columns.last {
                if candidate.minX > last.maxX - 0.025 && abs(candidate.midY - last.midY) < 0.07 && abs(candidate.height - last.height) < 0.1 { columns.append(candidate) }
            } else { columns.append(candidate) }
        }
        features.reelColumns = columns.count
        return Recognizer.classify(id: id, capturedAt: capturedAt, text: text, visuals: features)
    }

    public static func visualFeatures(_ image: CGImage) -> VisualEvidence {
        let width = 192, height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .init() }
        // The bitmap's row zero follows the source image's top row.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var cyan = 0, purple = 0, green = 0, red = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            if g > 0.3 && b > 0.3 && r < g * 0.65 && abs(g - b) < 0.25 { cyan += 1 }
            if r > 0.22 && b > 0.3 && g < min(r, b) * 0.8 { purple += 1 }
            if g > 0.25 && g > r * 1.35 && g > b * 1.25 { green += 1 }
            if r > 0.35 && r > g * 1.5 && r > b * 1.3 { red += 1 }
        }
        // A coarse circular border feature in the expected right-side control area.
        // This is a provisional profile, not full-image template matching.
        var bright = 0
        for index in 0..<40 {
            let angle = Double(index) * .pi * 2 / 40
            let x = Int(166 + cos(angle) * 10.5), y = Int(88 + sin(angle) * 10.5)
            let offset = (y * width + x) * 4
            if pixels[offset] > 185 && pixels[offset + 1] > 185 && pixels[offset + 2] > 160 { bright += 1 }
        }
        let count = Double(width * height)
        return .init(turquoise: Double(cyan) / count, purple: Double(purple) / count, green: Double(green) / count, red: Double(red) / count, spinRing: Double(bright) / 40)
    }
}
