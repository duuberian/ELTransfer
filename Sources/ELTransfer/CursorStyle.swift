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
    case circle, rounded, square
    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: "Circle"
        case .rounded: "Rounded Square"
        case .square: "Square"
        }
    }

    /// Corner radius as a fraction of the glyph's side.
    var cornerFraction: CGFloat {
        switch self {
        case .circle: 0.5
        case .rounded: 0.24
        case .square: 0
        }
    }

    // Older builds sent "arrow"; fall back rather than dropping their packets.
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

struct CursorGlyph: View {
    let color: CursorColor
    let shape: CursorShape
    var lineWidth: CGFloat = 3
    var filled = true

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) * shape.cornerFraction
            let outline = RoundedRectangle(cornerRadius: radius)
            outline.fill(filled ? color.fill : .clear)
                .overlay(outline.strokeBorder(color.stroke, lineWidth: lineWidth))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shape)
        }
    }
}
