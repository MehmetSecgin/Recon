import AppKit
import SwiftUI

enum ReconTheme {
    static let windowBackground = Color(hex: 0x2D2A2A)
    static let titlebarBackground = Color(hex: 0x262323)
    static let panelBackground = Color(hex: 0x211F1F)
    static let floatingPanelBackground = Color(hex: 0x171515)
    static let panelRaised = Color(hex: 0x3A3636)
    static let panelBorder = Color(hex: 0x4C4747)
    static let divider = Color(hex: 0x474343)
    static let textPrimary = Color(hex: 0xF5F2F2)
    static let textSecondary = Color(hex: 0xA8A2A2)
    static let textMuted = Color(hex: 0x7E7878)
    static let accent = Color(hex: 0xE04CD6)
    static let accentPressed = Color(hex: 0xC33AB9)
    static let accentSoft = Color(hex: 0x5A2A56)
    static let selectionBackground = Color(hex: 0x4F294B)
    static let selectionBorder = Color(hex: 0xE04CD6)
    static let danger = Color(hex: 0xFF5B57)
    static let dangerBackground = Color(hex: 0x573533)
    static let success = Color(hex: 0x48DF70)
    static let warning = Color(hex: 0xFFB14A)
    static let shadow = Color.black.opacity(0.22)

    static let windowBackgroundNSColor = NSColor(hex: 0x2D2A2A)
}

extension Color {
    init(hex: Int, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct ReconSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? ReconTheme.textPrimary : ReconTheme.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? ReconTheme.panelRaised : ReconTheme.panelRaised.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ReconTheme.panelBorder.opacity(isEnabled ? 1 : 0.4), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct ReconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(configuration.isOn ? ReconTheme.accent : ReconTheme.panelRaised)
                .frame(width: 42, height: 24)
                .overlay(
                    Circle()
                        .fill(ReconTheme.textPrimary)
                        .frame(width: 18, height: 18)
                        .offset(x: configuration.isOn ? 9 : -9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(configuration.isOn ? ReconTheme.accentPressed : ReconTheme.panelBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
