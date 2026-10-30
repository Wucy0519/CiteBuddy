import Foundation

struct CheckedEntry: Sendable {
    var record: BibRecord
    var verdict: Verdict
}

enum Verdict: Sendable {
    case match(url: String, notes: [String])
    case mismatch(url: String, reasons: [String])
    case missing(reasons: [String])
    case unavailable(String)
}

func bibliographyTitleList(_ text: String) -> String {
    let library = parseBib(text)
    return bibliographyTitleList(records: library.records, macros: library.macros)
}

func bibliographyTitleList(records: [BibRecord], macros: [String: String]) -> String {
    if records.isEmpty {
        return "没有找到文献条目。请粘贴 @article 或 @inproceedings。@String 会自动跳过。"
    }
    var lines = ["论文题目（\(records.count)）", ""]
    for record in records {
        let title = fieldText(record, "title", macros: macros)
        lines.append("\(record.index). \(title.isEmpty ? "（这条没有题名）" : title)")
    }
    return lines.joined(separator: "\n")
}

func verifyBibliography(_ text: String, progress: @escaping @Sendable (Int, Int, String, String) -> Void) async -> String {
    let library = parseBib(text)
    var records = library.records
    if records.isEmpty {
        return "没有找到文献条目。请粘贴 @article 或 @inproceedings。@String 会自动跳过。"
    }
    var truncated = false
    if records.count > 300 {
        records = Array(records.prefix(300))
        truncated = true
    }
    let client = DBLPClient(useCache: false)
    var outcomes: [CheckedEntry] = []
    var stopped = false
    for (offset, record) in records.enumerated() {
        if Task.isCancelled {
            stopped = true
            break
        }
        let title = displayTitle(record, macros: library.macros)
        let step = offset + 1
        progress(
            outcomes.count,
            records.count,
            "正在核查第 \(step) 条，共 \(records.count) 条：\(title)",
            finishedTitles(outcomes, macros: library.macros, processing: "正在核查第 \(step) 条：\(title)")
        )
        do {
            let verdict = try await checkOne(record, macros: library.macros, client: client)
            outcomes.append(CheckedEntry(record: record, verdict: verdict))
        } catch is CancellationError {
            stopped = true
            break
        } catch {
            outcomes.append(CheckedEntry(record: record, verdict: .unavailable(explain(error))))
        }
    }
    progress(
        outcomes.count,
        records.count,
        stopped ? "已停止" : "正在把核查结果打印到工作台",
        finishedTitles(outcomes, macros: library.macros, processing: nil)
    )
    return renderVerification(
        records: records,
        outcomes: outcomes,
        macros: library.macros,
        stopped: stopped,
        truncated: truncated
    )
}

func fetchBibliographies(_ text: String, progress: @escaping @Sendable (Int, Int, String, String) -> Void) async -> String {
    if text.contains("@article") || text.contains("@inproceedings") || text.contains("@String") {
        return "这看起来是 BibTeX，不是题目列表。请切换到「核查 BibTeX」。"
    }
    var titles = text.split(whereSeparator: \.isNewline).map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty && !$0.hasPrefix("%") && !$0.hasPrefix("#") }
    if titles.isEmpty {
        return "左侧还没有题目。每行写一个论文题名。"
    }
    var truncated = false
    if titles.count > 200 {
        titles = Array(titles.prefix(200))
        truncated = true
    }
    let client = DBLPClient()
    var blocks: [String] = []
    var found = 0
    var stopped = false
    for (offset, title) in titles.enumerated() {
        if Task.isCancelled {
            stopped = true
            break
        }
        let step = offset + 1
        progress(
            blocks.count,
            titles.count,
            "正在检索第 \(step) 行，共 \(titles.count) 行：\(title)",
            finishedFetches(blocks, processing: "正在检索第 \(step) 行：\(title)")
        )
        do {
            let block = try await fetchOne(title, client: client)
            if block.contains("\n@") || block.hasPrefix("@") { found += 1 }
            blocks.append(block)
        } catch is CancellationError {
            stopped = true
            break
        } catch {
            blocks.append("% 检索：\(title)\n% 失败：\(explain(error))")
        }
    }
    progress(
        blocks.count,
        titles.count,
        stopped ? "已停止" : "正在把 BibTeX 打印到工作台",
        finishedFetches(blocks, processing: nil)
    )
    var header = "引用工作台从 DBLP 抓取。题目 \(titles.count) 条，写入 BibTeX \(found) 条。"
    if stopped { header = "已停止。\(header)" }
    if truncated { header += " 一次最多 200 条，其余请分开抓取。" }
    return (["% " + header] + blocks).joined(separator: "\n\n")
}

private func fetchOne(_ title: String, client: DBLPClient) async throws -> String {
    let hits = try await client.search(title: title)
    let exact = hits.filter { titlesMatch(title, $0.title) }
    guard let chosen = preferExactHit(exact), let bibURL = chosen.bibURL else {
        var lines = ["% 检索：\(title)", "% 未在 DBLP 找到完全同名的文献。"]
        let near = nearestLines(title, hits: hits)
        if near.isEmpty {
            lines.append("% 没有题名接近的候选。")
        } else {
            lines.append("% 题名接近、但不会把它当成这篇论文：")
            lines.append(contentsOf: near.map { "% \($0)" })
        }
        return lines.joined(separator: "\n")
    }
    let data = try await client.load(bibURL)
    let bib = bodyText(data)
    guard bib.contains("@") else {
        return "% 检索：\(title)\n% 找到了 DBLP 记录，但没有拿到 BibTeX。\(chosen.pageURL)"
    }
    var header = [
        "% 检索：\(title)",
        "% 命中：\(chosen.title)  \([chosen.venue, chosen.year].filter { !$0.isEmpty }.joined(separator: " "))",
        "% \(chosen.pageURL)"
    ]
    let others = exact.filter { $0.pageURL != chosen.pageURL }
    if !others.isEmpty {
        header.append("% 同名的其他记录：")
        for other in others.prefix(6) {
            header.append("% - \(other.venue) \(other.year) \(other.pageURL)")
        }
    }
    return header.joined(separator: "\n") + "\n" + bib.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func checkOne(_ record: BibRecord, macros: [String: String], client: DBLPClient) async throws -> Verdict {
    let title = fieldText(record, "title", macros: macros)
    guard !canonical(title).isEmpty else {
        return .missing(reasons: ["这条没有题名，没法向 DBLP 核对。"])
    }
    var notes: [String] = []
    if let bibURL = dblpRecordURL(from: record.fields["biburl"] ?? "") {
        do {
            let data = try await client.load(bibURL)
            let text = bodyText(data)
            if let official = parseBib(text).records.first {
                let officialTitle = fieldText(official, "title", macros: [:])
                if titlesMatch(title, officialTitle) {
                    let diffs = diffRecords(pasted: record, pastedMacros: macros, official: official, officialMacros: [:])
                    if diffs.isEmpty { return .match(url: officialPage(bibURL), notes: []) }
                    return .mismatch(url: officialPage(bibURL), reasons: diffs)
                }
                notes.append("给出的 biburl 指向了另一篇：「\(officialTitle)」。")
            } else {
                notes.append("给出的 biburl 没有返回 BibTeX。")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DBLPError where isNotFound(error) {
            notes.append("给出的 biburl 在 DBLP 上不存在。")
        } catch {
            return .unavailable(explain(error))
        }
    }

    do {
        let hits = try await client.search(title: title)
        let exact = hits.filter { titlesMatch(title, $0.title) }
        if let chosen = preferExactHit(exact), let bibURL = chosen.bibURL {
            let data = try await client.load(bibURL)
            let text = bodyText(data)
            if let official = parseBib(text).records.first {
                let diffs = diffRecords(pasted: record, pastedMacros: macros, official: official, officialMacros: [:])
                if diffs.isEmpty { return .match(url: chosen.pageURL, notes: notes) }
                return .mismatch(url: chosen.pageURL, reasons: notes + diffs)
            }
        }
        var reasons = notes
        reasons.append("按题名在 DBLP 没有找到完全同名的文献。")
        let near = nearestLines(title, hits: hits)
        if !near.isEmpty {
            reasons.append("题名接近、但并不能当成同一篇：\n" + near.joined(separator: "\n"))
        }
        return .missing(reasons: reasons)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return .unavailable(explain(error))
    }
}

private func bodyText(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    return String(decoding: data, as: UTF8.self)
}

private func isNotFound(_ error: DBLPError) -> Bool {
    if case .notFound = error { return true }
    return false
}

private func officialPage(_ bibURL: URL) -> String {
    let text = bibURL.absoluteString
    return text.hasSuffix(".bib") ? String(text.dropLast(4)) : text
}

private func nearestLines(_ title: String, hits: [DBLPHit]) -> [String] {
    hits.map { ($0, tokenDice(title, $0.title)) }
        .filter { !titlesMatch(title, $0.0.title) && $0.1 >= 0.45 }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { hit, _ in
            let who: String
            if hit.authors.isEmpty { who = "" }
            else if hit.authors.count == 1 { who = hit.authors[0] }
            else { who = "\(hit.authors[0]) 等" }
            let place = [hit.year, hit.venue, who].filter { !$0.isEmpty }.joined(separator: " · ")
            return "- \(hit.title)（\(place)）\(hit.pageURL)"
        }
}

private func tokenDice(_ lhs: String, _ rhs: String) -> Double {
    let left = Set(canonical(lhs).split(separator: " "))
    let right = Set(canonical(rhs).split(separator: " "))
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
}

func finishedTitles(_ outcomes: [CheckedEntry], macros: [String: String], processing: String?) -> String {
    var lines: [String] = []
    for item in outcomes {
        lines.append(entryLabel(item.record, macros: macros))
        lines.append(passed(item) ? "通过" : "有疑问")
        if !passed(item) {
            lines.append(contentsOf: doubtLines(item))
        }
        lines.append("")
    }
    if let processing {
        lines.append(processing)
        lines.append("")
    }
    if !outcomes.isEmpty {
        lines.append(bibliographyTitleList(records: outcomes.map(\.record), macros: macros))
    }
    return lines.joined(separator: "\n")
}

private func passed(_ item: CheckedEntry) -> Bool {
    if case .match = item.verdict { return true }
    return false
}

private func doubtLines(_ item: CheckedEntry) -> [String] {
    switch item.verdict {
    case let .missing(reasons):
        return reasons
    case let .mismatch(_, reasons):
        return reasons
    case let .unavailable(message):
        return [message]
    case let .match(_, notes):
        return notes
    }
}

private func finishedFetches(_ blocks: [String], processing: String?) -> String {
    var parts = blocks
    if let processing { parts.append("% \(processing)") }
    return parts.joined(separator: "\n\n")
}

private func explain(_ error: Error) -> String {
    if let dblp = error as? DBLPError { return dblp.description }
    return error.localizedDescription
}

private func renderVerification(records: [BibRecord], outcomes: [CheckedEntry], macros: [String: String], stopped: Bool, truncated: Bool) -> String {
    let passedCount = outcomes.filter(passed).count
    let doubtCount = outcomes.count - passedCount
    var lines: [String] = []
    if stopped { lines.append("已停止。完成 \(outcomes.count) / \(records.count) 条。") }
    if truncated { lines.append("一次最多核查 300 条，其余没有继续。") }
    lines.append("通过 \(passedCount) 条，有疑问 \(doubtCount) 条。")
    lines.append("")
    for item in outcomes {
        lines.append(entryLabel(item.record, macros: macros))
        lines.append(passed(item) ? "通过" : "有疑问")
        if !passed(item) {
            lines.append(contentsOf: doubtLines(item))
        }
        lines.append("")
    }
    let duplicates = duplicateKeys(records)
    if !duplicates.isEmpty {
        lines.append("重复的引用键（BibTeX 里键必须唯一，这本身不是有疑问）")
        for (key, count) in duplicates {
            lines.append("- \(key) 出现 \(count) 次")
        }
        lines.append("")
    }
    lines.append("说明：本地 citation key、timestamp 和 bibsource 不参与判断。两边都写了的题名、作者、年份、期刊或会议、卷、期、页码、DOI 和 eprint 会逐项比较。")
    lines.append("")
    lines.append(bibliographyTitleList(records: outcomes.map(\.record), macros: macros))
    return lines.joined(separator: "\n")
}

private func entryLabel(_ record: BibRecord, macros: [String: String]) -> String {
    let key = record.key.isEmpty ? "（无键）" : record.key
    return "\(record.index). \(key) — \(displayTitle(record, macros: macros))"
}
