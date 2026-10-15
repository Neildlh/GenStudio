import AppKit
import SwiftUI
import XCTest
@testable import GenStudio

/// Renders the Final-quality badge in both forms, light and dark. Set `RADAR_RENDER_DIR` to keep the PNGs.
@MainActor
final class FinalQualityBadgeRenderTests: XCTestCase {
    func testTheBadgeRendersInBothFormsAndSchemes() throws {
        for scheme in [ColorScheme.dark, .light] {
            let view = VStack(alignment: .leading, spacing: 10) {
                Text("MiniMax-H3 FL2VA · ready" + ModelAdvisor.pickerNote(MediaModelCatalog.minimaxH3RecipeID)).font(.callout)
                FinalQualityBadge(recipeID: MediaModelCatalog.minimaxH3RecipeID)
                FinalQualityBadge(recipeID: MediaModelCatalog.minimaxH3RecipeID, compact: true)
                FinalQualityBadge(recipeID: MLXVideoModelCatalog.ltx23Q4RecipeID)
            }
            .frame(width: 360, alignment: .leading).padding(16)
            .background(scheme == .dark ? Color(white: 0.12) : .white).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(image.size.height, 60)
            if let directory = ProcessInfo.processInfo.environment["RADAR_RENDER_DIR"],
               let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "final-quality-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
