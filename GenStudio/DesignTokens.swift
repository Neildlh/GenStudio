//  DesignTokens.swift
//  The compilable mirror of DESIGN.md. Screens reference these tokens instead of
//  re-deciding surface colors, spacing, radii, or the accent per call site.
//  Keep in lockstep with DESIGN.md at the project root.

import SwiftUI

// MARK: - Surface (near-black elevation scale, matches the app icon's glossy dark sphere)
// Lighter = more elevated / more interactive. Replaces the five divergent
// `Color(white:)` literals that used to be scattered across node/card views.

enum Surface {
    /// Graph/canvas background behind everything.
    static let canvas = Color(white: 0.09)
    /// Standard node card / panel body.
    static let card = Color(white: 0.12)
    /// Image-output card body (sits under checkerboard/media content).
    static let cardImage = Color(white: 0.14)
    /// Prompt-styled cards (taller header, the "primary input" cards).
    static let cardProminent = Color(white: 0.155)
    /// Text editors, input fields, hover/pressed chip backgrounds.
    static let control = Color(white: 0.18)
    /// Popovers, menus, and topmost floating chrome.
    static let controlElevated = Color(white: 0.205)
}

// MARK: - Spacing (8pt rhythm, matches the node system's existing bodyInset/promptInset)

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let section: CGFloat = 48
}

// MARK: - Corner radii

enum Radius {
    /// Small chips/badges.
    static let xs: CGFloat = 6
    /// Preview thumbnails, compact controls. Matches `NodeLayout.previewCornerRadius`.
    static let sm: CGFloat = 8
    /// Standard node cards, panels. Matches `NodeLayout.cardCornerRadius`.
    static let md: CGFloat = 12
    /// Prominent/prompt cards. Matches `NodeLayout.prominentCardCornerRadius`.
    static let lg: CGFloat = 18
}

// MARK: - Canvas type scale
// The node canvas is its own fixed-zoom surface (NodeLayout geometry is all
// literal points, independent of system Dynamic Type), so it deliberately
// does NOT use the semantic `.body`/`.caption` ramp — those would reflow
// against a card chrome that can't resize to match. This is the equivalent
// fixed-point scale for that one surface, replacing what used to be seven
// ad hoc sizes (9/10/11/12/13/14/15) scattered across node chrome.

enum CanvasType {
    /// Smallest inline status text (progress readouts).
    static let micro: CGFloat = 9
    /// Secondary/meta text: socket labels, card footers, compact badges.
    static let label: CGFloat = 11
    /// Primary card content: preview text, compact node titles.
    static let body: CGFloat = 13
    /// The one editable/hero text per card: the prompt editor, prominent node titles.
    static let prominent: CGFloat = 14
}

// MARK: - Motion

enum Motion {
    static let standard: Animation = .spring(response: 0.32, dampingFraction: 0.85)
}

// MARK: - Brand accent (from the app icon: warm ember orange on near-black)

extension Color {
    /// The app's one dominant accent — used sharply for primary action, focus, and brand moments.
    static let brandAccent = Color(red: 1.0, green: 0.56, blue: 0.14)
}

// MARK: - Data-type colors (node graph ports/wires)
// Formalizes the port-color mapping that previously lived as a private
// function local to a single view file. Semantics unchanged.

enum DataTypeColor {
    static let text = Color.mint
    static let textArray = Color.cyan
    static let number = Color.blue
    /// Deliberately shares the brand accent's hue family — images are the app's primary medium.
    static let image = Color.orange
    static let video = Color.purple
    static let shotSequence = Color.pink

    static func forPort(_ type: PortDataType) -> Color {
        switch type {
        case .text: text
        case .textArray: textArray
        case .number: number
        case .image: image
        case .video: video
        case .shotSequence: shotSequence
        }
    }
}

// MARK: - Model-purpose colors (model library tagging)
// Formerly `ModelPurpose.tint(_ scheme: ColorScheme)`, a light+dark branching
// palette whose light branch was unreachable under the app's forced dark
// mode. Kept as the same dark-tuned hues, now a flat dark-only token set.

enum ModelPurposeColor {
    static let writing = Color(red: 0.79, green: 0.68, blue: 1)
    static let analysis = Color(red: 0.58, green: 0.77, blue: 1)
    static let imageGeneration = Color(red: 1, green: 0.65, blue: 0.81)
    static let imageUpscaling = Color(red: 0.70, green: 0.85, blue: 0.55)
    static let imageUnderstanding = Color(red: 0.43, green: 0.86, blue: 0.88)
    static let videoGeneration = Color(red: 1, green: 0.75, blue: 0.45)
    static let audio = Color(red: 0.51, green: 0.88, blue: 0.65)
    static let unknown = Color(white: 0.75)
}

// MARK: - Card surface helper

extension View {
    /// Standard elevated card: token surface, token radius.
    func cardStyle(surface: Color = Surface.card, radius: CGFloat = Radius.md) -> some View {
        self
            .padding(Space.md)
            .background(surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
