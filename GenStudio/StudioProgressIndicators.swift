import SwiftUI

/// SwiftUI-only progress indicators. AppKit's NSProgressIndicator can emit
/// invalid min/max length constraints when a view is proposed a very narrow
/// size (for example while the workflow canvas is zooming).
struct StudioSpinner: View {
    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(-20))
            .modifier(StudioSpinnerAnimation())
            .accessibilityLabel("Loading")
    }
}

private struct StudioSpinnerAnimation: ViewModifier {
    @State private var rotating = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotating ? 340 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

struct StudioLinearProgress: View {
    let value: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.22))
                if let value {
                    Capsule().fill(Color.accentColor).frame(width: width * min(max(value, 0), 1))
                } else {
                    Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: width * 0.28)
                        .modifier(StudioIndeterminateAnimation())
                }
            }
        }
        .frame(height: 4)
        // The indeterminate segment intentionally moves beyond either end of
        // the track. Clip at the shared indicator level so it cannot escape a
        // node card (or any other surface that uses this progress view).
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(min(max($0, 0), 1) * 100)) percent" } ?? "In progress")
    }
}

private struct StudioIndeterminateAnimation: ViewModifier {
    @State private var offset: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .offset(x: offset * 100)
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: offset)
            .onAppear { offset = 1 }
    }
}
