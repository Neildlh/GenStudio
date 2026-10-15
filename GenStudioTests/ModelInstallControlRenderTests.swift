import AppKit
import SwiftUI
import XCTest
@testable import GenStudio

/// Renders every Install-control state in a listing row and in the sidebar's narrow Discover row. Set
/// `RADAR_RENDER_DIR` to keep the PNGs for a visual check.
@MainActor
final class ModelInstallControlRenderTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appending(path: "InstallControlRender-\(UUID())", directoryHint: .isDirectory)
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func png<V: View>(_ view: V, width: CGFloat, name: String) throws {
        let framed = view.frame(width: width).padding(16).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "\(name) did not render")
        XCTAssertGreaterThan(image.size.height, 40)
        if let directory = ProcessInfo.processInfo.environment["RADAR_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appending(path: name + ".png"))
        }
    }

    private func row(_ store: ModelLibraryViewModel, _ recipe: ModelRecipe, action: String = "Install") -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ModelRecipePresentation.title(recipe)).font(.headline)
                Text(ModelRecipePresentation.purpose(recipe)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            ModelInstallControl(store: store, recipe: recipe, actionTitle: action) {}
        }
        .padding(Space.lg).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    func testEveryStateRendersInAListingRowAndTheSidebar() throws {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.hardware = HardwareProfile.current(storageURL: root)
        let recipes = ModelCatalog.recipes
        let z = try XCTUnwrap(recipes.first { $0.id == MediaModelCatalog.zImageTurboRecipeID })
        let klein = try XCTUnwrap(recipes.first { $0.id == MediaModelCatalog.klein9BRecipeID })
        let esrgan = try XCTUnwrap(recipes.first { $0.id == UpscaleCapabilityRegistry.realesrganX4PlusRecipeID })
        let ltx = try XCTUnwrap(recipes.first { $0.id == MediaModelCatalog.ltx23RecipeID })

        try png(VStack(spacing: 10) { row(store, z, action: "Download & Test"); row(store, ltx) }, width: 760, name: "install-ready-and-blocked")

        store.activeRecipeID = esrgan.id; store.progress = 0.42
        store.requestInstall(klein)
        try png(VStack(spacing: 10) { row(store, esrgan); row(store, klein); row(store, z, action: "Download & Test") }, width: 760, name: "install-downloading-queued")

        try png(VStack(alignment: .leading, spacing: 10) {
            ForEach([z, klein, esrgan], id: \.id) { recipe in
                HStack(alignment: .top, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ModelAdviceSection.shortName(recipe.id, fallback: recipe.name)).font(.callout.weight(.medium))
                        Text("About 2 minutes for a 1024² image.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.xs)
                    ModelInstallControl(store: store, recipe: recipe, size: .compact)
                }
            }
        }, width: 260, name: "install-sidebar")
    }
}
