import AppKit

/// `--snapshot <panel|setup|general|storage|appearance|pins|ignore|advanced> <file>`
/// renders a window to a PNG, so layouts can be checked without recording the screen.
extension AppController {
    func runSnapshot(kind: String, path: String, panel: PanelController) {
        // The capture is opaque white, so plain windows only read in light mode.
        if kind != "panel" { NSApp.appearance = NSAppearance(named: .aqua) }
        let view: NSView?
        switch kind {
        case "panel":
            panel.show(from: .hotkey)
            view = panel.snapshotView
        case "setup":
            let controller = SetupWindowController(preferences: preferencesForSnapshot)
            view = controller.preparedContent()
            retained = controller
        default:
            guard let store = storeForSnapshot else { return }
            let controller = SettingsWindowController(store: store, preferences: preferencesForSnapshot)
            view = controller.preparedContent(tab: kind)
            retained = controller
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                if let view { Self.write(view, to: path) }
                NSApp.terminate(nil)
            }
        }
    }

    private static func write(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let capture = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: capture)

        // Off screen there is no window behind the view, so compose over a matching gray.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor(white: isDark ? 0.16 : 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        capture.draw(in: NSRect(origin: .zero, size: bounds.size))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
