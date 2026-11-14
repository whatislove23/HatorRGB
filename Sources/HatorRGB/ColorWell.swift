import SwiftUI
import AppKit
import HatorKit

/// Drives the shared macOS colour panel. SwiftUI's ColorPicker loses its connection to the panel when
/// the menu bar window closes (which happens as soon as you click the panel), so the menu uses this:
/// the change handler writes straight into the model and keeps working after the menu is gone.
@MainActor
final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()
    private var onChange: ((RGB) -> Void)?

    func open(_ initial: RGB, onChange: @escaping (RGB) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = NSColor(initial.color)
        self.onChange = onChange
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        onChange?(RGB(Color(nsColor: panel.color)))
    }
}

/// A colour swatch that opens the colour panel when clicked.
struct RGBWell: View {
    let color: RGB
    let onChange: (RGB) -> Void

    var body: some View {
        Button {
            ColorPanelController.shared.open(color, onChange: onChange)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
                .frame(width: 36, height: 18)
        }
        .buttonStyle(.plain)
        .help("Вибрати колір")
    }
}
