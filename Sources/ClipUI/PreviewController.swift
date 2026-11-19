import AppKit
import ClipCore
import ClipPlatform
import ClipStore

/// The hover preview. Everything it shows is loaded on demand and released on dismissal.
@MainActor
final class PreviewController {
    private static let maxImageSide: CGFloat = 520
    private static let maxTextLength = 4_000
    private static let width: CGFloat = 420

    private let store: Store
    private var pending: DispatchWorkItem?
    private var popover: NSPopover?
    /// Discards an image that finishes loading after the selection moved on.
    private var generation = 0

    init(store: Store) {
        self.store = store
    }

    func schedule(row: ClipRow, delayMs: Int, anchor: @escaping () -> (NSView, NSRect)?) {
        dismiss()
        guard delayMs > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(row: row, anchor: anchor) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    func dismiss() {
        generation += 1
        pending?.cancel()
        pending = nil
        popover?.close()
        popover = nil
    }

    private func present(row: ClipRow, anchor: @escaping () -> (NSView, NSRect)?) {
        guard row.kind == .image else {
            show(makeContent(for: row, image: nil), anchor: anchor)
            return
        }
        generation += 1
        let current = generation
        Self.loadPreview(store: store, id: row.id, maxPixelSize: Int(Self.maxImageSide * 2)) { [weak self] data in
            guard let self, current == self.generation else { return }
            self.show(self.makeContent(for: row, image: data.flatMap(Self.image(from:))), anchor: anchor)
        }
    }

    /// `nonisolated` keeps the helper process wait off the main actor.
    private nonisolated static func loadPreview(
        store: Store, id: Int64, maxPixelSize: Int, completion: @escaping @MainActor @Sendable (Data?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let source = try? store.representations(id: id).first { KnownTypes.imagePriority.contains($0.uti) }?.data
            let preview = source.flatMap { Helper.preview(of: $0, maxPixelSize: maxPixelSize) }
            Task { @MainActor in completion(preview) }
        }
    }

    private static func image(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data), let pixels = image.representations.first else { return nil }
        let longest = CGFloat(max(pixels.pixelsWide, pixels.pixelsHigh))
        let scale = min(0.5, maxImageSide / max(longest, 1))
        image.size = NSSize(width: CGFloat(pixels.pixelsWide) * scale, height: CGFloat(pixels.pixelsHigh) * scale)
        return image
    }

    private func show(_ content: NSView, anchor: () -> (NSView, NSRect)?) {
        guard let (view, rect) = anchor(), view.window?.isVisible == true else { return }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.show(relativeTo: rect, of: view, preferredEdge: .minX)
        self.popover = popover
    }

    private func makeContent(for row: ClipRow, image: NSImage?) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        if let image {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: image.size.width),
                view.heightAnchor.constraint(equalToConstant: image.size.height),
            ])
            stack.addArrangedSubview(view)
        } else if let text = store.searchText(id: row.id), !text.isEmpty {
            let shown = text.count > Self.maxTextLength ? String(text.prefix(Self.maxTextLength)) + "…" : text
            let label = NSTextField(wrappingLabelWithString: shown)
            label.font = NSFont.systemFont(ofSize: 12)
            label.maximumNumberOfLines = 28
            label.lineBreakMode = .byTruncatingTail
            label.preferredMaxLayoutWidth = Self.width - 24
            stack.addArrangedSubview(label)
        }

        let info = NSTextField(wrappingLabelWithString: details(for: row))
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = Self.width - 24
        stack.addArrangedSubview(info)

        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        stack.frame = NSRect(origin: .zero, size: NSSize(width: max(fitting.width, 220), height: fitting.height))
        return stack
    }

    private func details(for row: ClipRow) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines: [String] = []
        if let bundle = row.sourceApp {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            lines.append("Application: " + (url.map { $0.deletingPathExtension().lastPathComponent } ?? bundle))
        }
        lines.append("First copy: " + formatter.string(from: row.firstCopied))
        lines.append("Last copy: " + formatter.string(from: row.lastCopied))
        lines.append("Copies: \(row.copyCount)")
        lines.append("Size: " + ByteCountFormatter.string(fromByteCount: row.byteSize, countStyle: .file))
        return lines.joined(separator: "\n")
    }
}
