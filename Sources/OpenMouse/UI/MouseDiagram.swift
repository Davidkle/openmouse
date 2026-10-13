import OpenMouseCore
import SwiftUI

/// Something selectable on the mouse illustration.
enum Hotspot: Hashable, Identifiable {
    case control(ButtonID)
    case thumbwheel

    var id: String {
        switch self {
        case let .control(b): return b.rawValue
        case .thumbwheel: return "thumbwheel"
        }
    }

    var label: String {
        switch self {
        case let .control(b): return b.label
        case .thumbwheel: return "Thumb Wheel"
        }
    }

    var symbol: String {
        switch self {
        case let .control(b): return b.symbol
        case .thumbwheel: return "dial.medium"
        }
    }

    /// Marker position in unit coordinates of the illustration.
    var anchor: CGPoint {
        switch self {
        case .control(.middleClick): return CGPoint(x: 0.52, y: 0.17)
        case .control(.wheelTiltLeft): return CGPoint(x: 0.38, y: 0.17)
        case .control(.wheelTiltRight): return CGPoint(x: 0.66, y: 0.17)
        case .control(.modeShift): return CGPoint(x: 0.53, y: 0.335)
        case .thumbwheel: return CGPoint(x: 0.11, y: 0.47)
        case .control(.forward): return CGPoint(x: 0.07, y: 0.585)
        case .control(.back): return CGPoint(x: 0.07, y: 0.665)
        case .control(.gestureButton): return CGPoint(x: 0.17, y: 0.81)
        case .control(.hapticPanel): return CGPoint(x: 0.27, y: 0.73)
        case .control: return CGPoint(x: 0.5, y: 0.5)
        }
    }
}

/// Stylized top-down illustration of an MX-style mouse with clickable hotspots.
struct MouseDiagram: View {
    let hotspots: [Hotspot]
    @Binding var selection: Hotspot
    var summary: (Hotspot) -> String

    private let aspect: CGFloat = 0.68

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            ZStack(alignment: .topLeading) {
                MouseBody()
                    .frame(width: size.width, height: size.height)
                    .offset(x: origin.x, y: origin.y)
                ForEach(hotspots) { spot in
                    HotspotMarker(spot: spot, selected: spot == selection, remapped: summary(spot) != "Default")
                        .position(x: origin.x + spot.anchor.x * size.width, y: origin.y + spot.anchor.y * size.height)
                        .onTapGesture { withAnimation(.snappy) { selection = spot } }
                        .help("\(spot.label): \(summary(spot))")
                }
            }
        }
        // No intrinsic aspect ratio: the drawing fits whatever space it gets, so
        // it never forces the window taller than the screen allows.
        .frame(minWidth: 160, minHeight: 220)
    }

    private func fitted(in size: CGSize) -> CGSize {
        let width = min(size.width, size.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}

private struct HotspotMarker: View {
    let spot: Hotspot
    let selected: Bool
    let remapped: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            if selected {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 40, height: 40)
            }
            Circle()
                .fill(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: selected ? 0 : 2)
                .frame(width: 26, height: 26)
            Image(systemName: spot.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
            if remapped && !selected {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .offset(x: 10, y: -10)
            }
        }
        .scaleEffect(hovering && !selected ? 1.12 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Circle().inset(by: -6))
        .accessibilityLabel(spot.label)
        .accessibilityAddTraits(.isButton)
    }
}

private struct MouseBody: View {
    var body: some View {
        Canvas { context, size in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }

            let outline = smoothClosedPath([
                p(0.50, 0.02), p(0.74, 0.05), p(0.88, 0.18), p(0.93, 0.42), p(0.92, 0.66), p(0.84, 0.86),
                p(0.62, 0.98), p(0.38, 0.97), p(0.20, 0.90), p(0.06, 0.78), p(0.05, 0.66), p(0.12, 0.52),
                p(0.14, 0.30), p(0.24, 0.09),
            ])
            let body = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(white: 0.36), Color(white: 0.22)]),
                startPoint: p(0.3, 0), endPoint: p(0.8, 1)
            )
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 12, y: 6))
                layer.fill(outline, with: body)
            }
            context.stroke(outline, with: .color(.white.opacity(0.12)), lineWidth: 1)

            // Thumb rest.
            let rest = smoothClosedPath([p(0.10, 0.72), p(0.22, 0.70), p(0.30, 0.80), p(0.24, 0.90), p(0.12, 0.86)])
            context.fill(rest, with: .color(.black.opacity(0.18)))

            // Button split.
            var split = Path()
            split.move(to: p(0.515, 0.03))
            split.addQuadCurve(to: p(0.53, 0.42), control: p(0.54, 0.2))
            context.stroke(split, with: .color(.black.opacity(0.45)), lineWidth: 1.5)

            // Main wheel.
            let wheel = Path(roundedRect: CGRect(origin: p(0.475, 0.085), size: CGSize(width: 0.09 * size.width, height: 0.17 * size.height)), cornerRadius: 0.04 * size.width)
            context.fill(wheel, with: .linearGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0.4)]), startPoint: p(0.47, 0.08), endPoint: p(0.57, 0.25)))
            for i in 0..<9 {
                let y = 0.1 + CGFloat(i) * 0.017
                var groove = Path()
                groove.move(to: p(0.485, y))
                groove.addLine(to: p(0.555, y))
                context.stroke(groove, with: .color(.black.opacity(0.25)), lineWidth: 1)
            }

            // Mode shift button.
            let shift = Path(roundedRect: CGRect(origin: p(0.505, 0.315), size: CGSize(width: 0.055 * size.width, height: 0.04 * size.height)), cornerRadius: 3)
            context.fill(shift, with: .color(Color(white: 0.45)))

            // Thumb wheel on the side.
            let thumb = Path(roundedRect: CGRect(origin: p(0.075, 0.42), size: CGSize(width: 0.07 * size.width, height: 0.10 * size.height)), cornerRadius: 4)
            context.fill(thumb, with: .color(Color(white: 0.5)))

            // Back / forward buttons.
            for y in [0.56, 0.64] {
                let button = Path(roundedRect: CGRect(origin: p(0.035, y), size: CGSize(width: 0.08 * size.width, height: 0.05 * size.height)), cornerRadius: 4)
                context.fill(button, with: .color(Color(white: 0.42)))
            }
        }
    }

    /// Closed path through midpoints of `points` using quadratic curves.
    private func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in 0..<points.count {
            let current = points[i]
            let next = points[(i + 1) % points.count]
            path.addQuadCurve(to: mid(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }
}
