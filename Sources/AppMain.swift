import AppKit

@main
enum CitationBenchMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if let code = CLI.runIfRequested() {
            exit(code)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bench = WorkbenchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        bench.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "开始", action: #selector(start), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: "停止", action: #selector(stop), keyEquivalent: ".").target = self
        appMenu.addItem(withTitle: "载入示例", action: #selector(loadExample), keyEquivalent: "e").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "复制工作台", action: #selector(copyOutput), keyEquivalent: "C").target = self
        appMenu.addItem(withTitle: "保存工作台…", action: #selector(saveOutput), keyEquivalent: "s").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出引用工作台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "查找", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        NSApp.mainMenu = main
    }

    @objc private func start() { bench.start() }
    @objc private func stop() { bench.stop() }
    @objc private func loadExample() { bench.loadExample() }
    @objc private func copyOutput() { bench.copyOutput() }
    @objc private func saveOutput() { bench.saveOutput() }
}

enum CLI {
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        if let path = value(after: "--verify", in: args) { return run(.verify, path: path) }
        if let path = value(after: "--fetch", in: args) { return run(.fetch, path: path) }
        return nil
    }

    private enum Job { case verify, fetch }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func run(_ job: Job, path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("打不开文件：\(path)\n", stderr)
            return 1
        }
        let group = DispatchGroup()
        group.enter()
        let box = ResultBox()
        Task.detached {
            let report: String
            switch job {
            case .verify:
                report = await verifyBibliography(text) { done, total, line, _ in
                    fputs("\(line)  \(done)/\(total)\n", stderr)
                }
            case .fetch:
                report = await fetchBibliographies(text) { done, total, line, _ in
                    fputs("\(line)  \(done)/\(total)\n", stderr)
                }
            }
            box.text = report
            group.leave()
        }
        group.wait()
        print(box.text)
        return 0
    }
}

private final class ResultBox: @unchecked Sendable {
    var text = ""
}

enum SelfTest {
    static func run() -> Int32 {
        var failures = bibSelfTest() + dblpSelfTest()
        if let url = Bundle.main.url(forResource: "sample", withExtension: "bib"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let library = parseBib(text)
            if library.records.count != 58 {
                failures.append("示例文献解析出 \(library.records.count) 条，应为 58")
            }
            let keys = Set(library.records.map(\.key))
            for key in ["bruce2024genie", "vggtomega", "ocrv6", "alexnet", "hu2022lora", "wang2020tsrn"] where !keys.contains(key) {
                failures.append("示例里缺少 \(key)")
            }
            if library.records.contains(where: { fieldText($0, "title", macros: library.macros).isEmpty }) {
                failures.append("有条目没有题名")
            }
            if library.records.contains(where: { $0.raw.dropFirst().contains("\n@") }) {
                failures.append("有条目把下一条吞进去了")
            }
            let duplicates = Dictionary(grouping: library.records, by: \.key).mapValues(\.count)
            if duplicates["bai2023qwenvl"] != 2 || duplicates["hu2022lora"] != 2 || duplicates["loshchilov2019adamw"] != 2 {
                failures.append("重复键数量不对：\(duplicates.filter { $0.value > 1 })")
            }
            if let omega = library.records.first(where: { $0.key == "vggtomega" }), omega.raw.contains("@String") {
                failures.append("VGGT-Omega 那条把后面的 @String 吞进去了")
            }
            if library.macros["pami"] == nil || library.macros["cvpr"] == nil {
                failures.append("示例里的 @String 没有读到")
            }
            let titles = bibliographyTitleList(text)
            if !titles.hasPrefix("论文题目（58）") {
                failures.append("题目列表开头不对：\(titles.prefix(40))")
            }
            if !titles.contains("1. Genie: Generative Interactive Environments") || !titles.contains("VGGT-Ω") {
                failures.append("题目没有从 BibTeX 里抽出来")
            }
            if titles.contains("IEEE TPAMI") || titles.contains("Pattern Recognition") {
                failures.append("@String 被当成了论文题目")
            }
            let one = CheckedEntry(record: library.records[0], verdict: .match(url: "https://dblp.org", notes: []))
            let board = finishedTitles([one], macros: library.macros, processing: "正在核查第 2 条：下一篇")
            let titleAt = board.range(of: "论文题目")
            let passedAt = board.range(of: "通过")
            if titleAt == nil || passedAt == nil || titleAt!.lowerBound < passedAt!.lowerBound {
                failures.append("论文题目没有排在核查结果后面")
            }
            if !board.contains("1. Genie: Generative Interactive Environments") || board.contains("2. Stable Video Diffusion") || !board.contains("通过") {
                failures.append("处理第 2 条时，工作台没有只留下第 1 条并标成通过")
            }
        } else {
            failures.append("应用里没有示例文献")
        }
        if failures.isEmpty {
            fputs("self-test ok\n", stderr)
            return 0
        }
        for failure in failures {
            fputs(failure + "\n", stderr)
        }
        return 1
    }
}
