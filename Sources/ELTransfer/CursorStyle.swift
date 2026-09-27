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
    case arrow, circle, square
    var id: String { rawValue }
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
        shape = defaults.string(forKey: "cursorShape").flatMap(CursorShape.init) ?? .arrow
    }
}

/// Pointer arrow traced from the design sketch; the tip sits at the rect's top-left.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Keep the sketch's proportions and pin the tip to the top-left corner.
        let height = min(rect.height, rect.width * 218 / 165)
        let width = height * 165 / 218
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * width, y: rect.minY + y * height) }
        var path = Path()
        path.move(to: p(0, 0))
        path.addLine(to: p(1, 0.555))
        path.addLine(to: p(0.40, 0.58))
        path.addLine(to: p(0.16, 1))
        path.closeSubpath()
        return path
    }
}

struct CursorGlyph: View {
    let color: CursorColor
    let shape: CursorShape
    var lineWidth: CGFloat = 3

    var body: some View {
        switch shape {
        case .arrow:
            ArrowShape().fill(color.fill)
                .overlay(ArrowShape().stroke(color.stroke, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)))
        case .circle:
            Circle().fill(color.fill).overlay(Circle().strokeBorder(color.stroke, lineWidth: lineWidth))
        case .square:
            RoundedRectangle(cornerRadius: lineWidth * 1.5).fill(color.fill)
                .overlay(RoundedRectangle(cornerRadius: lineWidth * 1.5).strokeBorder(color.stroke, lineWidth: lineWidth))
        }
    }
}
