import AppKit
import UniformTypeIdentifiers

final class WorkbenchController: NSObject, NSWindowDelegate, NSSplitViewDelegate, @unchecked Sendable {
    private let window: NSWindow
    private let segments = NSSegmentedControl(labels: ["按题目抓取", "核查 BibTeX"], trackingMode: .selectOne, target: nil, action: nil)
    private let leftCaption = NSTextField(labelWithString: "论文题目，每行一个")
    private let subtitle: NSTextField
    private var input: NSTextView!
    private var output: NSTextView!
    private var runButton: NSButton!
    private var stopButton: NSButton!
    private var exampleButton: NSButton!
    private var progress: NSProgressIndicator!
    private var status: NSTextField!
    private var task: Task<Void, Never>?
    private var split: NSSplitView!
    private var mode = Mode.fetch

    private enum Mode {
        case fetch, verify
    }

    override init() {
        subtitle = NSTextField(wrappingLabelWithString: "左侧每行一个论文题目，从 DBLP 抓取 BibTeX，打印到右侧工作台。也可以粘贴 BibTeX，先把论文题目列在右侧，再列出对不上 DBLP 的疑似幻觉引用。")
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "引用工作台"
        window.minSize = NSSize(width: 860, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        if !window.setFrameAutosaveName("CitationBenchMain") {
            window.center()
        }
        updateSubtitleWidth()
        window.makeKeyAndOrderFront(nil)
        balanceSplit()
        DispatchQueue.main.async { [weak self] in self?.balanceSplit() }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimum: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimum, 280)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximum: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximum, splitView.bounds.width - 320)
    }

    private func balanceSplit() {
        window.layoutIfNeeded()
        let width = split.bounds.width
        guard width > 640 else { return }
        let left = split.arrangedSubviews.first?.bounds.width ?? 0
        if left < 300 || left > width - 340 {
            split.setPosition(floor(width * 0.42), ofDividerAt: 0)
        }
    }

    func start() {
        guard task == nil else { return }
        let source = input.string
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status.stringValue = mode == .fetch ? "先在左侧写上论文题目，每行一个。" : "先在左侧粘贴 BibTeX。"
            return
        }
        setRunning(true)
        output.string = ""
        status.stringValue = mode == .verify
            ? "开始核查。每处理完一条，就标出通过或有疑问，题目印在文末。"
            : "开始抓取。每处理完一行，BibTeX 就印到右侧。"
        progress.doubleValue = 0
        let current = mode
        task = Task {
            let report: String
            let onProgress: @Sendable (Int, Int, String, String) -> Void = { done, total, line, workbench in
                DispatchQueue.main.async { self.showProgress(done, total, line, workbench) }
            }
            if current == .fetch {
                report = await fetchBibliographies(source, progress: onProgress)
            } else {
                report = await verifyBibliography(source, progress: onProgress)
            }
            DispatchQueue.main.async {
                self.showWorkbench(report, scrollToEnd: false)
                self.task = nil
                self.setRunning(false)
                self.status.stringValue = "已打印到工作台。"
            }
        }
    }

    func stop() {
        task?.cancel()
        status.stringValue = "正在停止，当前这一条结束后就停。"
    }

    func loadExample() {
        let resource = mode == .fetch ? "titles" : "sample"
        let ext = mode == .fetch ? "txt" : "bib"
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            status.stringValue = "示例还没有放进应用里。"
            return
        }
        input.string = text
        status.stringValue = mode == .fetch ? "已载入示例题目。点「抓取并打印到工作台」。" : "已载入测试文献。点「核查并列出疑似幻觉」。"
    }

    func copyOutput() {
        guard !output.string.isEmpty else {
            status.stringValue = "工作台还是空的。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.string, forType: .string)
        status.stringValue = "工作台内容已复制。"
    }

    func saveOutput() {
        guard !output.string.isEmpty else {
            status.stringValue = "工作台还是空的。"
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = mode == .fetch ? "dblp.bib" : "核查报告.txt"
        if mode == .fetch {
            panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.output.string.write(to: url, atomically: true, encoding: .utf8)
                self.status.stringValue = "已保存到 \(url.path)"
            } catch {
                self.status.stringValue = "没有保存成功。"
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        updateSubtitleWidth()
    }

    private func showProgress(_ done: Int, _ total: Int, _ line: String, _ workbench: String) {
        progress.maxValue = Double(max(total, 1))
        progress.doubleValue = Double(done)
        status.stringValue = line
        guard !workbench.isEmpty else { return }
        showWorkbench(workbench, scrollToEnd: true)
    }

    private func showWorkbench(_ text: String, scrollToEnd: Bool) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        mark("通过", color: .systemGreen, font: bold, in: attributed)
        mark("有疑问", color: .systemRed, font: bold, in: attributed)
        output.textStorage?.setAttributedString(attributed)
        let location = scrollToEnd ? attributed.length : 0
        output.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    private func mark(_ word: String, color: NSColor, font: NSFont, in text: NSMutableAttributedString) {
        let raw = text.string as NSString
        var search = NSRange(location: 0, length: raw.length)
        while search.length > 0 {
            let found = raw.range(of: word, range: search)
            if found.location == NSNotFound { break }
            text.addAttributes([.font: font, .foregroundColor: color], range: found)
            let next = found.location + found.length
            search = NSRange(location: next, length: raw.length - next)
        }
    }

    private func setRunning(_ running: Bool) {
        runButton.isEnabled = !running
        exampleButton.isEnabled = !running
        segments.isEnabled = !running
        stopButton.isEnabled = running
        progress.isHidden = !running
    }

    @objc private func switchMode() {
        mode = segments.selectedSegment == 0 ? .fetch : .verify
        if mode == .fetch {
            leftCaption.stringValue = "论文题目，每行一个"
            runButton.title = "抓取并打印到工作台"
        } else {
            leftCaption.stringValue = "粘贴 BibTeX"
            runButton.title = "核查并列出疑似幻觉"
        }
    }

    private func updateSubtitleWidth() {
        subtitle.preferredMaxLayoutWidth = max(320, window.contentLayoutRect.width - 8)
    }

    private func build() {
        let root = NSView()
        window.contentView = root

        let title = NSTextField(labelWithString: "引用工作台")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.maximumNumberOfLines = 3

        segments.target = self
        segments.action = #selector(switchMode)
        segments.selectedSegment = 0

        leftCaption.font = .systemFont(ofSize: 13, weight: .medium)
        let rightCaption = NSTextField(labelWithString: "工作台")
        rightCaption.font = .systemFont(ofSize: 13, weight: .medium)

        let (leftScroll, leftText) = makeEditor(rich: false)
        let (rightScroll, rightText) = makeEditor(rich: true)
        input = leftText
        output = rightText
        output.string = "抓取到的 BibTeX，或疑似幻觉引用，会打印在这里。"

        let leftPane = NSView()
        let rightPane = NSView()
        pin(caption: leftCaption, scroll: leftScroll, in: leftPane)
        pin(caption: rightCaption, scroll: rightScroll, in: rightPane)

        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "CitationBenchSplit"
        split.addArrangedSubview(leftPane)
        split.addArrangedSubview(rightPane)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        runButton = NSButton(title: "抓取并打印到工作台", target: self, action: #selector(startClicked))
        stopButton = NSButton(title: "停止", target: self, action: #selector(stopClicked))
        exampleButton = NSButton(title: "载入示例", target: self, action: #selector(exampleClicked))
        let copyButton = NSButton(title: "复制工作台", target: self, action: #selector(copyClicked))
        let saveButton = NSButton(title: "保存…", target: self, action: #selector(saveClicked))
        for button in [runButton!, stopButton!, exampleButton!, copyButton, saveButton] {
            button.bezelStyle = .rounded
        }
        stopButton.isEnabled = false

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 150).isActive = true

        status = NSTextField(labelWithString: "准备好了。向 DBLP 大约每秒查询一条。")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail

        let buttons = NSStackView(views: [runButton, stopButton, exampleButton, copyButton, saveButton, progress])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        for view in [title, subtitle, segments, split!, buttons, status!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            segments.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            segments.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    private func pin(caption: NSTextField, scroll: NSScrollView, in pane: NSView) {
        caption.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(caption)
        pane.addSubview(scroll)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 2),
            caption.topAnchor.constraint(equalTo: pane.topAnchor),
            caption.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
    }

    private func makeEditor(rich: Bool) -> (NSScrollView, NSTextView) {
        let text = NSTextView()
        text.isRichText = rich
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.enabledTextCheckingTypes = 0
        text.usesFindBar = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = text
        return (scroll, text)
    }

    @objc private func startClicked() { start() }
    @objc private func stopClicked() { stop() }
    @objc private func exampleClicked() { loadExample() }
    @objc private func copyClicked() { copyOutput() }
    @objc private func saveClicked() { saveOutput() }
}
