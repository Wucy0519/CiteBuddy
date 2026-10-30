import Foundation

struct BibRecord: Sendable {
    var index: Int
    var type: String
    var key: String
    var fields: [String: String]
    var raw: String

    init(index: Int = 0, type: String, key: String, fields: [String: String], raw: String) {
        self.index = index
        self.type = type
        self.key = key
        self.fields = fields
        self.raw = raw
    }
}

struct BibLibrary: Sendable {
    var records: [BibRecord]
    var macros: [String: String]
}

func parseBib(_ original: String) -> BibLibrary {
    let text = normalizeQuotes(original)
    var records: [BibRecord] = []
    var macros: [String: String] = [:]
    var cursor = text.startIndex
    while cursor < text.endIndex {
        guard let at = text[cursor...].firstIndex(of: "@") else { break }
        if let parsed = parseAt(text, at: at) {
            switch parsed.kind {
            case let .macro(name, value):
                if macros[name] == nil { macros[name] = value }
            case let .record(record):
                records.append(record)
            case .skip:
                break
            }
            cursor = parsed.end
        } else {
            cursor = text.index(after: at)
        }
    }
    for i in records.indices {
        records[i].index = i + 1
    }
    return BibLibrary(records: records, macros: macros)
}

private enum ParsedKind {
    case record(BibRecord)
    case macro(String, String)
    case skip
}

private struct ParsedAt {
    var end: String.Index
    var kind: ParsedKind
}

private func parseAt(_ text: String, at: String.Index) -> ParsedAt? {
    var i = text.index(after: at)
    while i < text.endIndex, text[i].isLetter {
        i = text.index(after: i)
    }
    let type = text[text.index(after: at)..<i].lowercased()
    guard !type.isEmpty else { return nil }
    while i < text.endIndex, text[i].isWhitespace {
        i = text.index(after: i)
    }
    guard i < text.endIndex, text[i] == "{" || text[i] == "(" else { return nil }
    guard let end = matchDelimited(text, openAt: i) else { return nil }
    let innerStart = text.index(after: i)
    let innerEnd = text.index(before: end)
    guard innerStart <= innerEnd else { return nil }
    let inner = String(text[innerStart..<innerEnd])
    let raw = String(text[at..<end])
    if type == "string" {
        guard let (name, value) = assignment(inner) else {
            return ParsedAt(end: end, kind: .skip)
        }
        return ParsedAt(end: end, kind: .macro(name, value))
    }
    if type == "comment" || type == "preamble" {
        return ParsedAt(end: end, kind: .skip)
    }
    let parts = splitTop(inner, separator: ",")
    let key = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var fields: [String: String] = [:]
    for part in parts.dropFirst() {
        guard let (name, value) = assignment(part) else { continue }
        fields[name] = value
    }
    guard fields["title"] != nil || fields["author"] != nil || fields["year"] != nil else {
        return ParsedAt(end: end, kind: .skip)
    }
    let record = BibRecord(type: type, key: key, fields: fields, raw: raw)
    return ParsedAt(end: end, kind: .record(record))
}

private func matchDelimited(_ text: String, openAt: String.Index) -> String.Index? {
    let opener = text[openAt]
    var braces = 0
    var parens = 0
    var i = openAt
    while i < text.endIndex {
        let c = text[i]
        if c == "{" { braces += 1 }
        else if c == "}" { braces -= 1 }
        else if c == "(" { parens += 1 }
        else if c == ")" { parens -= 1 }
        let next = text.index(after: i)
        if opener == "{", braces == 0 { return next }
        if opener == "(", parens == 0, braces == 0 { return next }
        i = next
    }
    return nil
}

private func assignment(_ part: String) -> (String, String)? {
    guard let eq = firstTop(part, separator: "=") else { return nil }
    let name = part[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.range(of: #"^[A-Za-z][A-Za-z0-9_\-]*$"#, options: .regularExpression) != nil else {
        return nil
    }
    guard !value.isEmpty else { return nil }
    return (name, value)
}

private func firstTop(_ text: String, separator: Character) -> String.Index? {
    var braces = 0
    var parens = 0
    var quote = false
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\"", braces == 0 { quote.toggle() }
        if !quote {
            if c == "{" { braces += 1 }
            else if c == "}" { braces = max(0, braces - 1) }
            else if c == "(" { parens += 1 }
            else if c == ")" { parens = max(0, parens - 1) }
            else if c == separator, braces == 0, parens == 0 { return i }
        }
        i = text.index(after: i)
    }
    return nil
}

private func splitTop(_ text: String, separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var braces = 0
    var parens = 0
    var quote = false
    for c in text {
        if c == "\"", braces == 0 { quote.toggle() }
        if !quote {
            if c == "{" { braces += 1 }
            else if c == "}" { braces = max(0, braces - 1) }
            else if c == "(" { parens += 1 }
            else if c == ")" { parens = max(0, parens - 1) }
            else if c == separator, braces == 0, parens == 0 {
                parts.append(current)
                current = ""
                continue
            }
        }
        current.append(c)
    }
    parts.append(current)
    return parts
}

func fieldText(_ record: BibRecord, _ name: String, macros: [String: String]) -> String {
    guard let raw = record.fields[name] else { return "" }
    return latexToPlain(interpret(raw, macros: macros, depth: 0))
}

private func interpret(_ raw: String, macros: [String: String], depth: Int) -> String {
    if depth > 8 { return raw }
    let parts = splitTop(raw, separator: "#")
    return parts.map { piece -> String in
        let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inner = wrapped(token, by: "{", and: "}") {
            return inner
        }
        if token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") {
            return String(token.dropFirst().dropLast())
        }
        if let macro = macros[token] ?? macros[token.lowercased()] {
            return interpret(macro, macros: macros, depth: depth + 1)
        }
        return token
    }.joined(separator: " ")
}

private func wrapped(_ text: String, by open: Character, and close: Character) -> String? {
    guard text.first == open, text.last == close, text.count >= 2 else { return nil }
    var depth = 0
    var index = text.startIndex
    while index < text.endIndex {
        let c = text[index]
        if c == open { depth += 1 }
        else if c == close {
            depth -= 1
            if depth == 0 {
                return text.index(after: index) == text.endIndex
                    ? String(text[text.index(after: text.startIndex)..<index])
                    : nil
            }
        }
        index = text.index(after: index)
    }
    return nil
}

func latexToPlain(_ input: String) -> String {
    var text = input.replacingOccurrences(of: #"\(\Omega\)"#, with: "Ω")
    text = text.replacingOccurrences(of: #"\Omega"#, with: "Ω")
    text = replaceAccents(text)
    let symbols = [
        "{--}": "--",
        "{-}": "-",
        "\\&": "&",
        "\\%": "%",
        "\\_": "_",
        "\\#": "#",
        "\\$": "$",
        "\\ ": " "
    ]
    for (from, to) in symbols {
        text = text.replacingOccurrences(of: from, with: to)
    }
    text = text.replacingOccurrences(of: "~", with: " ")
    text = text.filter { $0 != "{" && $0 != "}" && $0 != "\\" }
    return text.split { $0.isWhitespace }.joined(separator: " ")
}

private func replaceAccents(_ input: String) -> String {
    let chars = Array(input)
    var out = ""
    var i = 0
    while i < chars.count {
        if chars[i] == "\\", i + 1 < chars.count, isAccentCommand(chars[i + 1]) {
            let command = chars[i + 1]
            var j = i + 2
            if j < chars.count, chars[j] == "{" { j += 1 }
            if j + 1 < chars.count, chars[j] == "\\", chars[j + 1] == "i", let letter = accent(command, "i") {
                out.append(letter)
                j += 2
                if j < chars.count, chars[j] == "}" { j += 1 }
                i = j
                continue
            }
            if j < chars.count, chars[j].isLetter, let letter = accent(command, chars[j]) {
                out.append(letter)
                j += 1
                if j < chars.count, chars[j] == "}" { j += 1 }
                i = j
                continue
            }
        }
        out.append(chars[i])
        i += 1
    }
    return out
}

private func isAccentCommand(_ c: Character) -> Bool {
    c == "\"" || c == "'" || c == "`" || c == "^" || c == "~" || c == "." || c == "c"
}

private func accent(_ command: Character, _ letter: Character) -> String? {
    let maps: [Character: [Character: String]] = [
        "\"": ["a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "A": "Ä", "E": "Ë", "I": "Ï", "O": "Ö", "U": "Ü"],
        "'": ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "Y": "Ý", "c": "ć", "n": "ń", "s": "ś", "z": "ź", "C": "Ć", "N": "Ń"],
        "`": ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"],
        "^": ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û", "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"],
        "~": ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
        ".": ["z": "ż", "Z": "Ż"],
        "c": ["c": "ç", "C": "Ç"]
    ]
    return maps[command]?[letter]
}

func canonical(_ text: String) -> String {
    var plain = latexToPlain(text)
    plain = plain.replacingOccurrences(of: "Ω", with: "omega")
    plain = plain.replacingOccurrences(of: "ω", with: "omega")
    plain = plain.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    plain = plain.replacingOccurrences(of: "ß", with: "ss")
    let filtered = plain.map { ($0.isLetter || $0.isNumber) ? $0 : " " }
    return String(filtered).split { $0 == " " }.joined(separator: " ")
}

func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = canonical(lhs)
    let right = canonical(rhs)
    return !left.isEmpty && left == right
}

func authorNames(_ record: BibRecord, macros: [String: String]) -> [String] {
    let text = fieldText(record, "author", macros: macros)
    guard !text.isEmpty else { return [] }
    return text.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func authorKeys(_ record: BibRecord, macros: [String: String]) -> Set<String> {
    Set(authorNames(record, macros: macros).map(authorKey))
}

func authorKey(_ name: String) -> String {
    var text = name
    if let regex = try? NSRegularExpression(pattern: "\\([^)]*\\)") {
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    return canonical(text).split { $0 == " " }.map(String.init).sorted().joined(separator: " ")
}

func normYear(_ text: String) -> String {
    guard let match = text.range(of: #"\d{4}"#, options: .regularExpression) else { return "" }
    return String(text[match])
}

func normDOI(_ text: String) -> String {
    var value = latexToPlain(text).lowercased()
    for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] {
        if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
    }
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "./ "))
}

func normPages(_ text: String) -> String {
    var value = latexToPlain(text).lowercased()
    value = value.replacingOccurrences(of: "—", with: "-")
    value = value.replacingOccurrences(of: "–", with: "-")
    while value.contains("--") {
        value = value.replacingOccurrences(of: "--", with: "-")
    }
    return value.filter { !$0.isWhitespace }
}

func normToken(_ text: String) -> String {
    latexToPlain(text).lowercased().filter { !$0.isWhitespace }
}

func venuesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = canonical(lhs)
    let right = canonical(rhs)
    if left.isEmpty || right.isEmpty { return true }
    if left == right { return true }
    if left.count >= 4, right.contains(left) { return true }
    if right.count >= 4, left.contains(right) { return true }
    return false
}

func diffRecords(pasted: BibRecord, pastedMacros: [String: String], official: BibRecord, officialMacros: [String: String]) -> [String] {
    var reasons: [String] = []
    let pastedTitle = fieldText(pasted, "title", macros: pastedMacros)
    let officialTitle = fieldText(official, "title", macros: officialMacros)
    if !titlesMatch(pastedTitle, officialTitle) {
        reasons.append(contrast("题名", pastedTitle, officialTitle))
    }
    let pastedYear = normYear(fieldText(pasted, "year", macros: pastedMacros))
    let officialYear = normYear(fieldText(official, "year", macros: officialMacros))
    if !pastedYear.isEmpty, !officialYear.isEmpty, pastedYear != officialYear {
        reasons.append(contrast("年份", pastedYear, officialYear))
    }
    let pastedAuthors = authorKeys(pasted, macros: pastedMacros)
    let officialAuthors = authorKeys(official, macros: officialMacros)
    if !pastedAuthors.isEmpty, !officialAuthors.isEmpty, pastedAuthors != officialAuthors {
        reasons.append(contrast(
            "作者",
            authorNames(pasted, macros: pastedMacros).joined(separator: "; "),
            authorNames(official, macros: officialMacros).joined(separator: "; ")
        ))
    }
    for name in ["journal", "booktitle"] {
        let left = fieldText(pasted, name, macros: pastedMacros)
        let right = fieldText(official, name, macros: officialMacros)
        if left.isEmpty || right.isEmpty { continue }
        if !venuesMatch(left, right) {
            reasons.append(contrast(name == "journal" ? "期刊" : "会议或书名", left, right))
        }
    }
    compareToken("页码", normPages(fieldText(pasted, "pages", macros: pastedMacros)), normPages(fieldText(official, "pages", macros: officialMacros)), into: &reasons)
    compareToken("卷号", normToken(fieldText(pasted, "volume", macros: pastedMacros)), normToken(fieldText(official, "volume", macros: officialMacros)), into: &reasons)
    compareToken("期号", normToken(fieldText(pasted, "number", macros: pastedMacros)), normToken(fieldText(official, "number", macros: officialMacros)), into: &reasons)
    compareToken("DOI", normDOI(fieldText(pasted, "doi", macros: pastedMacros)), normDOI(fieldText(official, "doi", macros: officialMacros)), into: &reasons)
    compareToken("eprint", normToken(fieldText(pasted, "eprint", macros: pastedMacros)), normToken(fieldText(official, "eprint", macros: officialMacros)), into: &reasons)
    return reasons
}

private func compareToken(_ label: String, _ pasted: String, _ official: String, into reasons: inout [String]) {
    if pasted.isEmpty || official.isEmpty || pasted == official { return }
    reasons.append(contrast(label, pasted, official))
}

private func contrast(_ label: String, _ pasted: String, _ official: String) -> String {
    "\(label)不一致。粘贴为「\(squash(pasted))」，DBLP 为「\(squash(official))」。"
}

private func squash(_ text: String) -> String {
    let flat = text.split { $0.isWhitespace }.joined(separator: " ")
    if flat.count <= 360 { return flat }
    return String(flat.prefix(360)) + "…"
}

private func normalizeQuotes(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

func displayTitle(_ record: BibRecord, macros: [String: String]) -> String {
    let title = fieldText(record, "title", macros: macros)
    return title.isEmpty ? record.key : title
}

func bibSelfTest() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }
    expect(canonical(#"Rockt{\"{a}}schel"#) == canonical("Rocktäschel"), "变音符号没有还原")
    expect(canonical(#"VGGT-{\(\Omega\)}"#).contains("omega"), "希腊字母 Ω 没有还原")
    expect(canonical(#"Jack Parker{-}Holder"#) == canonical("Jack Parker-Holder"), "连字符姓名没有对齐")
    expect(normPages("4603--4623") == "4603-4623", "页码连字符没有对齐")
    expect(normDOI("10.48550/ARXIV.1") == normDOI("https://doi.org/10.48550/arXiv.1"), "DOI 没有对齐")
    expect(authorKey(#"Tim Rockt{\"{a}}schel"#) == authorKey("Tim Rocktäschel"), "作者变音符号没有对齐")
    expect(authorKey("Jianyuan Wang") == authorKey("Wang, Jianyuan"), "作者姓和名的顺序没有对齐")

    let sameAuthors = BibRecord(type: "article", key: "a", fields: [
        "title": "{Same Title}",
        "year": "{2024}",
        "author": "{Ann Lee and Bob Wu}",
        "pages": "{1--5}",
        "doi": "{10.1000/ABC}"
    ], raw: "")
    let reordered = BibRecord(type: "article", key: "b", fields: [
        "title": "{Same Title.}",
        "year": "{2024}",
        "author": "{Bob Wu and Ann Lee}",
        "pages": "{1-5}",
        "doi": "{https://doi.org/10.1000/abc}"
    ], raw: "")
    expect(diffRecords(pasted: sameAuthors, pastedMacros: [:], official: reordered, officialMacros: [:]).isEmpty, "相同文献被误判成不一致")
    let wrongYear = BibRecord(type: "article", key: "c", fields: [
        "title": "{Same Title}",
        "year": "{2023}",
        "author": "{Ann Lee and Bob Wu}"
    ], raw: "")
    let yearDiff = diffRecords(pasted: sameAuthors, pastedMacros: [:], official: wrongYear, officialMacros: [:])
    expect(yearDiff.count == 1 && yearDiff[0].contains("年份"), "年份不同没有被查出来")

    let glue = #"""
    @inproceedings{vggtomega,
      title        = {VGGT-{\(\Omega\)}},
      year         = {2026},
      author       = {Ada Lovelace}
    } @String(PAMI = {IEEE TPAMI})
    @article{next,
      title        = {Next Paper},
      year         = {2020},
      author       = {Grace Hopper}
    }
    """#
    let library = parseBib(glue)
    expect(library.records.map(\.key) == ["vggtomega", "next"], "粘在一起的 @String 把条目拆坏了：\(library.records.map(\.key))")
    expect(library.macros["pami"] != nil, "没有读到 @String")
    expect(!library.records[0].raw.contains("@String"), "第一条把后面的 @String 吞进去了")
    expect(canonical(fieldText(library.records[0], "title", macros: library.macros)).contains("omega"), "条目里的 Ω 没有读出来")
    return failures
}

func duplicateKeys(_ records: [BibRecord]) -> [(String, Int)] {
    var counts: [String: Int] = [:]
    for record in records where !record.key.isEmpty {
        counts[record.key, default: 0] += 1
    }
    return counts.filter { $0.value > 1 }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
}
