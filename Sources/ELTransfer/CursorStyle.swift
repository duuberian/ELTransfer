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

/// Pointer arrow traced from the design sketch; the tip sits at the rect's top-left.
struct ArrowShape: Shape {
    /// Width over height of the sketch.
    static let aspect: CGFloat = 166 / 218
    var rounded = false

    func path(in rect: CGRect) -> Path {
        // Keep the sketch's proportions and pin the tip to the top-left corner.
        let height = min(rect.height, rect.width / Self.aspect)
        let width = height * Self.aspect
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.56), CGPoint(x: 0.404, y: 0.582), CGPoint(x: 0.163, y: 1)]
            .map { CGPoint(x: $0.x * Self.aspect, y: $0.y) }
        var path = Path()
        if rounded {
            // Start midway along the last edge so every corner, the tip included, is rounded.
            let last = corners[corners.count - 1]
            path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
            for index in corners.indices {
                path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % corners.count],
                            radius: 0.07)
            }
        } else {
            path.addLines(corners)
        }
        path.closeSubpath()
        // Rounding trims the sharp tips; stretch the outline back to the sketch's full size.
        let bounds = path.boundingRect
        return path.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: width / bounds.width, y: height / bounds.height))
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
