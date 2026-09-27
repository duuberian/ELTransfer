import AppKit
import SwiftUI

/// ELWifi's website palette, adapted for light and dark appearances.
enum ELStyle {
    static let paper = adaptive(light: 0xFFF0DF, dark: 0x252321)
    static let surface = adaptive(light: 0xFFF8EF, dark: 0x302D29)
    static let soft = adaptive(light: 0xF4E4D2, dark: 0x37312B)
    static let line = adaptive(light: 0xE8D5C2, dark: 0x584B40)
    static let selected = adaptive(light: 0xE3CDBD, dark: 0x4A4037)
    static let ink = adaptive(light: 0x2D2725, dark: 0xFFF0DF)
    static let muted = adaptive(light: 0x7D6254, dark: 0xCBB6A6)

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            hex(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

enum CursorColor: String, CaseIterable, Codable, Identifiable {
    case red, green, blue, yellow, purple
    var id: String { rawValue }

    var fill: Color {
        switch self {
        case .red: Color(nsColor: ELStyle.hex(0xF7C9C9))
        case .green: Color(nsColor: ELStyle.hex(0xC2F0C2))
        case .blue: Color(nsColor: ELStyle.hex(0xB3D6F8))
        case .yellow: Color(nsColor: ELStyle.hex(0xFDEBA0))
        case .purple: Color(nsColor: ELStyle.hex(0xDDCCF5))
        }
    }

    var stroke: Color {
        switch self {
        case .red: Color(nsColor: ELStyle.hex(0xD2423A))
        case .green: Color(nsColor: ELStyle.hex(0x4A9A4A))
        case .blue: Color(nsColor: ELStyle.hex(0x2F6FC4))
        case .yellow: Color(nsColor: ELStyle.hex(0xE39A2B))
        case .purple: Color(nsColor: ELStyle.hex(0x7A4FC0))
        }
    }
}

enum CursorShape: String, CaseIterable, Codable, Identifiable {
    case circle, rounded, arrow
    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: "Circle"
        case .rounded: "Rounded Pointer"
        case .arrow: "Pointer"
        }
    }

    var isPointer: Bool { self != .circle }

    // Unknown values from other builds fall back rather than dropping their packets.
    init(from decoder: Decoder) throws {
        self = CursorShape(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .circle
    }
}

/// The receiver's pointer look, remembered between launches and sent with each packet.
final class CursorSettings: ObservableObject {
    static let shared = CursorSettings()

    @Published var color: CursorColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "cursorColor") }
    }
    @Published var shape: CursorShape {
        didSet { UserDefaults.standard.set(shape.rawValue, forKey: "cursorShape") }
    }

    private init() {
        let defaults = UserDefaults.standard
        color = defaults.string(forKey: "cursorColor").flatMap(CursorColor.init) ?? .red
        shape = defaults.string(forKey: "cursorShape").flatMap(CursorShape.init) ?? .circle
    }
}

/// Pointer arrow from the design sketch, made symmetric about its axis and tilted
/// like a system pointer; the tip sits at the rect's top-left.
struct ArrowShape: Shape {
    /// Tip, wing, notch, wing, in the sketch's pixels. Both wings are the same length and
    /// the notch sits on the axis, then the axis leans 30° left of straight down.
    private static let outline: [CGPoint] = {
        let wing = CGPoint(x: 84, y: 196), notch: CGFloat = 142
        let tilt = CGAffineTransform(rotationAngle: -30.4 * .pi / 180)
        let points = [CGPoint.zero, wing, CGPoint(x: 0, y: notch), CGPoint(x: -wing.x, y: wing.y)]
        return points.map { $0.applying(tilt) }
    }()
    /// Width over height of the tilted outline.
    static let aspect: CGFloat = {
        let xs = outline.map(\.x), ys = outline.map(\.y)
        return (xs.max()! - xs.min()!) / (ys.max()! - ys.min()!)
    }()
    var rounded = false

    func path(in rect: CGRect) -> Path {
        // Keep the sketch's proportions and pin the tip to the top-left corner.
        let height = min(rect.height, rect.width / Self.aspect)
        let width = height * Self.aspect
        let corners = Self.outline
        var path = Path()
        if rounded {
            // Start midway along the last edge so every corner, the tip included, is rounded.
            let last = corners[corners.count - 1]
            path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
            for index in corners.indices {
                path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % corners.count],
                            radius: 15)
            }
        } else {
            path.addLines(corners)
        }
        path.closeSubpath()
        // Rounding trims the sharp tips; scale the outline back up evenly so it stays symmetric.
        let bounds = path.boundingRect
        let scale = min(width / bounds.width, height / bounds.height)
        return path.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct CursorGlyph: View {
    let color: CursorColor
    let shape: CursorShape
    var lineWidth: CGFloat = 3
    var filled = true

    var body: some View {
        switch shape {
        case .circle:
            Circle().fill(filled ? color.fill : .clear)
                .overlay(Circle().strokeBorder(color.stroke, lineWidth: lineWidth))
        case .rounded, .arrow:
            let arrow = ArrowShape(rounded: shape == .rounded)
            let join: CGLineJoin = shape == .rounded ? .round : .miter
            // Inset by half the stroke so the outline stays inside the frame.
            arrow.fill(filled ? color.fill : .clear)
                .overlay(arrow.stroke(color.stroke, style: StrokeStyle(lineWidth: lineWidth, lineJoin: join, miterLimit: 20)))
                .padding(lineWidth / 2)
                .aspectRatio(ArrowShape.aspect, contentMode: .fit)
        }
    }
}
