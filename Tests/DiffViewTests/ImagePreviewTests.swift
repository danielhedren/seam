import AppKit
import Testing

@testable import DiffView

@MainActor
@Suite struct ImagePreviewTests {
    @Test func captionsGiveABitmapsPixelsNotItsPoints() throws {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 80, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 80, height: 40)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let image = try #require(NSImage(data: data))
        #expect(image.size == NSSize(width: 80, height: 40))
        let pixels = DiffCanvasView.pixelSize(of: image)
        #expect((pixels.width, pixels.height) == (160, 80))
    }

    @Test func vectorImagesGiveTheirSizeInPoints() {
        let image = NSImage(size: NSSize(width: 24.4, height: 12), flipped: false) { _ in true }
        let pixels = DiffCanvasView.pixelSize(of: image)
        #expect((pixels.width, pixels.height) == (24, 12))
    }

    /// Visible against the background, but quieter than any text; stronger with Increase Contrast.
    @Test func theCheckerboardIsSubtleButVisible() {
        for (name, palette) in DiffPalette.all {
            let ratio = palette.checker.contrast(with: palette.background)
            #expect(ratio > 1.15 && ratio < 2, "\(name): checker is \(ratio)")
        }
        func ratio(_ palette: DiffPalette) -> Double {
            palette.checker.contrast(with: palette.background)
        }
        #expect(ratio(.lightHighContrast) > ratio(.light))
        #expect(ratio(.darkHighContrast) > ratio(.dark))
    }
}
