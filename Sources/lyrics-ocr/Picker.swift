import AppKit

@MainActor
func pickRegions(image: CGImage, lanes: [(id: String, language: String)]) -> Template? {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
    let scale = min(1100 / CGFloat(image.width), (screen.width - 70) / CGFloat(image.width),
                    (screen.height - 150) / CGFloat(image.height))
    let size = CGSize(width: max(500, CGFloat(image.width) * scale),
                      height: max(320, CGFloat(image.height) * scale + 62))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = L("选择歌词区域", "Select subtitle regions")
    window.minSize = CGSize(width: 520, height: 340)
    window.center()

    let picker = RegionPicker(image: image, lanes: lanes)
    window.contentView = picker
    window.delegate = picker
    window.makeKeyAndOrderFront(nil)
    app.activate()
    let result = app.runModal(for: window)
    window.orderOut(nil)
    return result == .OK ? Template(regions: picker.regions) : nil
}

@MainActor
private final class RegionPicker: NSView, NSWindowDelegate {
    let image: CGImage
    let lanes: [(id: String, language: String)]
    private let preview: DragPreview
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private lazy var save = NSButton(title: L("保存模板", "Save template"), target: self, action: #selector(accept))
    private lazy var undo = NSButton(title: L("撤销", "Undo"), target: self, action: #selector(removeLast))
    private(set) var regions: [Region] = []

    init(image: CGImage, lanes: [(id: String, language: String)]) {
        self.image = image
        self.lanes = lanes
        preview = DragPreview(image: image)
        super.init(frame: .zero)

        let cancel = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(closePicker))
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        let bar = NSStackView(views: [instructions, undo, cancel, save])
        bar.spacing = 10
        bar.alignment = .centerY
        instructions.setContentHuggingPriority(.defaultLow, for: .horizontal)
        instructions.maximumNumberOfLines = 2
        for view in [preview, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        preview.onSelection = { [weak self] rect in
            guard let self, self.regions.count < self.lanes.count else { return }
            let lane = self.lanes[self.regions.count]
            self.regions.append(Region(id: lane.id, language: lane.language, x: rect.minX, y: rect.minY,
                                       width: rect.width, height: rect.height))
            self.update()
        }
        update()
    }

    required init?(coder: NSCoder) { nil }

    private func update() {
        let complete = regions.count == lanes.count
        instructions.stringValue = complete
            ? L("已选好 \(regions.count) 个字幕框。", "\(regions.count) regions selected.")
            : L("拖动鼠标框出 \(lanes[regions.count].id)（\(lanes[regions.count].language)）的字幕区域。", "Drag to mark the subtitle area for \(lanes[regions.count].id) (\(lanes[regions.count].language)).")
        preview.regions = regions
        preview.acceptsSelection = !complete
        preview.needsDisplay = true
        save.isEnabled = complete
        undo.isEnabled = !regions.isEmpty
    }

    @objc private func removeLast() {
        if !regions.isEmpty { regions.removeLast() }
        update()
    }

    @objc private func accept() { NSApp.stopModal(withCode: .OK) }
    @objc private func closePicker() { NSApp.stopModal(withCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePicker()
        return false
    }
}

@MainActor
private final class DragPreview: NSView {
    let image: NSImage
    var regions: [Region] = []
    var acceptsSelection = true
    var onSelection: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?
    override var isFlipped: Bool { true }

    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private var imageRect: CGRect {
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let frame = imageRect
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let colors: [NSColor] = [.systemYellow, .systemCyan, .systemPink, .systemGreen]
        for (index, region) in regions.enumerated() {
            let color = colors[index % colors.count]
            let rect = CGRect(x: frame.minX + region.x * frame.width, y: frame.minY + region.y * frame.height,
                              width: region.width * frame.width, height: region.height * frame.height)
            color.withAlphaComponent(0.2).setFill()
            rect.fill()
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
        if let rect = selection {
            NSColor.white.withAlphaComponent(0.2).setFill()
            rect.fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    private var selection: CGRect? {
        guard let start, let end else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(start.x - end.x), height: abs(start.y - end.y))
        return rect.intersection(imageRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard acceptsSelection, imageRect.contains(point) else { return }
        start = point
        end = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        end = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        end = convert(event.locationInWindow, from: nil)
        if let rect = selection, rect.width >= 6, rect.height >= 6 {
            let frame = imageRect
            onSelection?(CGRect(x: (rect.minX - frame.minX) / frame.width,
                                y: (rect.minY - frame.minY) / frame.height,
                                width: rect.width / frame.width, height: rect.height / frame.height))
        }
        start = nil
        end = nil
        needsDisplay = true
    }
}
