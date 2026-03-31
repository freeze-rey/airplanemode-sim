import AppKit
import SwiftUI

struct AirplaneModeApp: App {
    @State private var store = AirplaneModeStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(store)
                .task { await store.syncOnAppear() }
        } label: {
            Image(nsImage: menuBarIcon)
                .task { await store.syncOnAppear() }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: NSImage {
        let size = NSSize(width: 24, height: 22)
        let dotColor = statusNSColor

        let image = NSImage(size: size, flipped: false) { bounds in
            // Detect if menu bar is dark from current drawing appearance
            let isDark = NSAppearance.currentDrawing()
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let symbolColor: NSColor = isDark ? .white : .black

            // Draw airplane SF Symbol
            if let symbol = NSImage(systemSymbolName: "airplane", accessibilityDescription: "AirplaneMode"),
               let configured = symbol.withSymbolConfiguration(
                   .init(pointSize: 13, weight: .medium)
               ) {
                let symbolRect = CGRect(
                    x: (bounds.width - configured.size.width) / 2 - 1,
                    y: (bounds.height - configured.size.height) / 2,
                    width: configured.size.width,
                    height: configured.size.height
                )
                // Tint the symbol
                let tinted = NSImage(size: configured.size, flipped: false) { tintBounds in
                    configured.draw(in: tintBounds)
                    symbolColor.setFill()
                    tintBounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: symbolRect)
            }

            // Draw colored status dot (bottom-right)
            let dotSize: CGFloat = 6
            let dotRect = CGRect(
                x: bounds.width - dotSize,
                y: 1,
                width: dotSize,
                height: dotSize
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = false
        return image
    }

    private var statusNSColor: NSColor {
        if !store.isActive { return .systemGray }
        if store.errorMessage != nil { return .systemYellow }
        return .systemGreen
    }
}
