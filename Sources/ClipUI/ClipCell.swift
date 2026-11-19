import AppKit
import ClipCore

/// Hex color preview. With alpha, the diagonal splits opaque from translucent.
final class SwatchView: NSView {
    var color: UInt32 = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let red = CGFloat((color >> 24) & 0xFF) / 255
        let green = CGFloat((color >> 16) & 0xFF) / 255
        let blue = CGFloat((color >> 8) & 0xFF) / 255
        let alpha = CGFloat(color & 0xFF) / 255
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).addClip()
        NSColor.white.setFill()
        rect.fill()
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).setFill()
        rect.fill()
        if alpha < 1 {
            let opaque = NSBezierPath()
            opaque.move(to: NSPoint(x: rect.minX, y: rect.minY))
            opaque.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            opaque.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            opaque.close()
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
            opaque.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Keeps the selection blue while the search field holds first responder.
final class ClipRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class ClipCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")
    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let boldFont = NSFont.boldSystemFont(ofSize: 13)

    private let thumbnail = NSImageView()
    private let appIcon = NSImageView()
    private let swatch = SwatchView()
    private let title = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var thumbnailSize = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        title.font = Self.titleFont
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.truncatesLastVisibleLine = true
        title.maximumNumberOfLines = 1
        title.textColor = .labelColor
        shortcut.font = NSFont.systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        for view in [thumbnail, appIcon, swatch, title, shortcut] { addSubview(view) }
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(
        row: ClipRow, displayTitle: String, highlight: String?, shortcutText: String?,
        image: NSImage?, imageHeight: CGFloat, icon: NSImage?
    ) {
        if let highlight, let range = displayTitle.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
            let attributed = NSMutableAttributedString(string: displayTitle, attributes: [.font: Self.titleFont])
            attributed.addAttribute(.font, value: Self.boldFont, range: NSRange(range, in: displayTitle))
            title.attributedStringValue = attributed
        } else {
            title.stringValue = displayTitle
        }
        title.isHidden = displayTitle.isEmpty
        shortcut.stringValue = shortcutText ?? ""

        thumbnail.image = image
        thumbnail.isHidden = image == nil
        if image != nil, row.thumbHeight > 0 {
            let height = min(imageHeight, CGFloat(row.thumbHeight) / 2)
            thumbnailSize = NSSize(width: height * CGFloat(row.thumbWidth) / CGFloat(row.thumbHeight), height: height)
        } else {
            thumbnailSize = .zero
        }

        swatch.isHidden = row.color == nil
        if let color = row.color { swatch.color = color }
        appIcon.image = icon
        appIcon.isHidden = icon == nil
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { shortcut.cell?.backgroundStyle = backgroundStyle }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 4
        if !appIcon.isHidden {
            appIcon.frame = NSRect(x: x, y: (height - 16) / 2, width: 16, height: 16)
            x += 22
        }
        if !swatch.isHidden {
            swatch.frame = NSRect(x: x, y: (height - 18) / 2, width: 18, height: 18)
            x += 26
        }
        if !thumbnail.isHidden {
            thumbnail.frame = NSRect(
                x: x, y: (height - thumbnailSize.height) / 2,
                width: thumbnailSize.width, height: thumbnailSize.height
            )
            x += thumbnailSize.width + 8
        }
        let shortcutWidth: CGFloat = shortcut.stringValue.isEmpty ? 0 : 50
        shortcut.frame = NSRect(x: bounds.width - shortcutWidth - 4, y: (height - 16) / 2, width: shortcutWidth, height: 16)
        title.frame = NSRect(x: x, y: (height - 17) / 2, width: max(0, bounds.width - x - shortcutWidth - 12), height: 17)
    }
}
