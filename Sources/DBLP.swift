import CryptoKit
import Foundation

struct DBLPHit: Sendable {
    var title: String
    var year: String
    var venue: String
    var type: String
    var key: String
    var authors: [String]
    var recordURL: String

    var bibURL: URL? {
        let base: String
        if !recordURL.isEmpty {
            base = recordURL.hasSuffix(".bib") ? String(recordURL.dropLast(4)) : recordURL
        } else if !key.isEmpty {
            base = "https://dblp.org/rec/\(key)"
        } else {
            return nil
        }
        return URL(string: base + ".bib")
    }

    var pageURL: String {
        if recordURL.isEmpty { return key.isEmpty ? "" : "https://dblp.org/rec/\(key)" }
        return recordURL.hasSuffix(".bib") ? String(recordURL.dropLast(4)) : recordURL
    }
}

enum DBLPError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case notFound
    case http(Int)
    case challengeFailed(String)
    case badResponse(String)
    case curl(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notFound:
            return "DBLP 没有这条记录"
        case let .http(code) where code == 429:
            return "DBLP 暂时限制了查询频率。稍后再试这一条。"
        case let .http(code):
            return "DBLP 返回 HTTP \(code)"
        case let .challengeFailed(detail):
            return "没能完成 DBLP 的访问校验。\(detail)"
        case let .badResponse(detail):
            return detail
        case let .curl(detail):
            return "连接 DBLP 失败。\(detail)"
        }
    }
}

actor DBLPClient {
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    private let jar: URL
    private let cache: URL
    private var lastRequest = Date.distantPast
    private let gap: TimeInterval = 1.2
    private let cacheTTL: TimeInterval = 12 * 60 * 60
    private let useCache: Bool

    init(useCache: Bool = true) {
        self.useCache = useCache
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("引用工作台/v1", isDirectory: true)
        cache = base.appendingPathComponent("pages", isDirectory: true)
        jar = base.appendingPathComponent("cookies.txt")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: jar.path) {
            FileManager.default.createFile(atPath: jar.path, contents: Data("# Netscape HTTP Cookie File\n".utf8))
        }
    }

    func search(title: String) async throws -> [DBLPHit] {
        var query = latexToPlain(title)
        if query.count > 240 { query = String(query.prefix(240)) }
        guard var components = URLComponents(string: "https://dblp.org/search/publ/api") else {
            throw DBLPError.badResponse("无法构造 DBLP 检索地址")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "h", value: "30")
        ]
        guard let url = components.url else { throw DBLPError.badResponse("无法构造 DBLP 检索地址") }
        let data = try await load(url)
        return try parseHits(data)
    }

    func load(_ url: URL) async throws -> Data {
        if useCache, let cached = readCache(url) { return cached }
        for attempt in 0..<6 {
            try Task.checkCancellation()
            let result = try await request(url)
            if result.status == 429 {
                if attempt == 5 { throw DBLPError.http(429) }
                try await Task.sleep(nanoseconds: UInt64(min(45, 8 * (attempt + 1))) * 1_000_000_000)
                continue
            }
            if result.status == 202 || isChallenge(result.body) {
                try await passChallenge(for: url, html: result.body)
                continue
            }
            if result.status == 200 {
                if useCache, !isChallenge(result.body) { writeCache(url, result.body) }
                return result.body
            }
            if result.status == 404 || result.status == 410 { throw DBLPError.notFound }
            throw DBLPError.http(result.status)
        }
        throw DBLPError.challengeFailed("连续几次都停在校验页。")
    }

    private func passChallenge(for page: URL, html: Data) async throws {
        let challenge = try parseChallenge(html)
        guard challenge.algorithm == "fast" || challenge.algorithm == "slow" else {
            throw DBLPError.challengeFailed("站点给出了\(challenge.algorithm)校验。")
        }
        guard challenge.difficulty <= 7 else {
            throw DBLPError.challengeFailed("校验难度过高（\(challenge.difficulty)）。")
        }
        let solved = try await Task.detached(priority: .userInitiated) {
            try solveProof(randomData: challenge.random, difficulty: challenge.difficulty)
        }.value
        guard var components = URLComponents(string: "https://dblp.org/.within.website/x/cmd/anubis/api/pass-challenge") else {
            throw DBLPError.challengeFailed("无法提交校验。")
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: challenge.id),
            URLQueryItem(name: "response", value: solved.hash),
            URLQueryItem(name: "nonce", value: String(solved.nonce)),
            URLQueryItem(name: "redir", value: page.absoluteString),
            URLQueryItem(name: "elapsedTime", value: String(max(solved.milliseconds, 1)))
        ]
        guard let passURL = components.url else { throw DBLPError.challengeFailed("无法提交校验。") }
        keepVerificationCookie()
        var result = try await request(passURL)
        if result.status == 429 {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            result = try await request(passURL)
        }
        if result.status == 429 { throw DBLPError.http(429) }
        if !(200...399).contains(result.status) {
            throw DBLPError.challengeFailed("提交后得到 HTTP \(result.status)。")
        }
    }

    /// A stale sign-in cookie makes DBLP keep showing the check page. Keep only the fresh verification cookie before submitting the check.
    private func keepVerificationCookie() {
        let text = (try? String(contentsOf: jar, encoding: .utf8)) ?? ""
        var header: [String] = []
        var verification: String?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if line.hasPrefix("#") {
                header.append(line)
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 6, fields[5].contains("cookie-verification") {
                verification = line
            }
        }
        if header.isEmpty { header = ["# Netscape HTTP Cookie File"] }
        if let verification { header.append(verification) }
        try? (header.joined(separator: "\n") + "\n").write(to: jar, atomically: true, encoding: .utf8)
    }

    private func request(_ url: URL) async throws -> (status: Int, body: Data) {
        await pace()
        let jar = self.jar
        let userAgent = self.userAgent
        return try await Task.detached(priority: .userInitiated) {
            try curl(url: url, userAgent: userAgent, cookieJar: jar)
        }.value
    }

    private func pace() async {
        let wait = gap - Date().timeIntervalSince(lastRequest)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastRequest = Date()
    }

    private func readCache(_ url: URL) -> Data? {
        let file = cache.appendingPathComponent(cacheName(url))
        guard let data = try? Data(contentsOf: file), let newline = data.firstIndex(of: 10) else { return nil }
        let header = String(data: data[..<newline], encoding: .utf8) ?? ""
        guard header.hasPrefix("T:"), let stamp = TimeInterval(header.dropFirst(2)) else { return nil }
        if Date().timeIntervalSince1970 - stamp > cacheTTL { return nil }
        let body = data[(data.index(after: newline))...]
        guard cacheable(url, body) else { return nil }
        return Data(body)
    }

    private func writeCache(_ url: URL, _ body: Data) {
        guard cacheable(url, body) else { return }
        var data = Data("T:\(Int(Date().timeIntervalSince1970))\n".utf8)
        data.append(body)
        try? data.write(to: cache.appendingPathComponent(cacheName(url)), options: .atomic)
    }

    private func cacheName(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct Proof {
    var hash: String
    var nonce: Int
    var milliseconds: Int
}

private struct Challenge {
    var id: String
    var random: String
    var difficulty: Int
    var algorithm: String
}

private func solveProof(randomData: String, difficulty: Int) throws -> Proof {
    let fullBytes = difficulty / 2
    let halfNibble = difficulty % 2 == 1
    let started = Date()
    var nonce = 0
    let prefix = Array(randomData.utf8)
    while nonce <= 40_000_000 {
        if nonce.isMultiple(of: 20_000), Task.isCancelled { throw CancellationError() }
        var bytes = prefix
        bytes.append(contentsOf: Array(String(nonce).utf8))
        let digest = Array(SHA256.hash(data: bytes))
        var ok = true
        if fullBytes > 0 {
            for index in 0..<fullBytes where digest[index] != 0 {
                ok = false
                break
            }
        }
        if ok, halfNibble, digest[fullBytes] >> 4 != 0 { ok = false }
        if ok {
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return Proof(hash: hash, nonce: nonce, milliseconds: elapsed)
        }
        nonce += 1
    }
    throw DBLPError.challengeFailed("校验计算没有在合理时间内完成。")
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func parseChallenge(_ data: Data) throws -> Challenge {
    guard let text = String(data: data, encoding: .utf8),
          let marker = text.range(of: "id=\"anubis_challenge\""),
          let open = text.range(of: ">", range: marker.upperBound..<text.endIndex),
          let close = text.range(of: "</script>", range: open.upperBound..<text.endIndex) else {
        throw DBLPError.challengeFailed("校验页格式变了。")
    }
    let json = Data(text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
          let rules = object["rules"] as? [String: Any],
          let challenge = object["challenge"] as? [String: Any],
          let id = challenge["id"] as? String,
          let random = challenge["randomData"] as? String,
          let algorithm = rules["algorithm"] as? String else {
        throw DBLPError.challengeFailed("校验页格式变了。")
    }
    let difficulty = intValue(rules["difficulty"])
    guard difficulty > 0 else { throw DBLPError.challengeFailed("校验难度无效。") }
    return Challenge(id: id, random: random, difficulty: difficulty, algorithm: algorithm)
}

private func intValue(_ value: Any?) -> Int {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String, let number = Int(text) { return number }
    return 0
}

private func cacheable(_ url: URL, _ body: Data) -> Bool {
    guard !body.isEmpty, !isChallenge(body) else { return false }
    if url.path.hasSuffix(".bib") {
        return String(data: body.prefix(300), encoding: .utf8)?.contains("@") == true
    }
    if url.absoluteString.contains("format=json") {
        let text = String(data: body.prefix(80), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.hasPrefix("{")
    }
    return true
}

func dblpSelfTest() -> [String] {
    var failures: [String] = []
    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    if sha256Hex("abc") != expected { failures.append("sha256 结果不对") }
    do {
        let proof = try solveProof(randomData: "citation-bench", difficulty: 2)
        if !proof.hash.hasPrefix("00") || proof.hash != sha256Hex("citation-bench\(proof.nonce)") {
            failures.append("访问校验的哈希不正确")
        }
    } catch {
        failures.append("访问校验自测失败")
    }
    return failures
}

private func isChallenge(_ data: Data) -> Bool {
    guard let text = String(data: data.prefix(8000), encoding: .utf8) else { return false }
    return text.contains("anubis_challenge") || text.contains("Making sure") || text.contains("不是机器人")
}

private func curl(url: URL, userAgent: String, cookieJar: URL) throws -> (status: Int, body: Data) {
    let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let headerFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: bodyFile)
        try? FileManager.default.removeItem(at: headerFile)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "-sS", "--max-time", "45",
        "-A", userAgent,
        "-H", "Accept: */*",
        "-b", cookieJar.path,
        "-c", cookieJar.path,
        "-D", headerFile.path,
        "-o", bodyFile.path,
        "-w", "%{http_code}",
        url.absoluteString
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        throw DBLPError.curl("找不到 curl。")
    }
    process.waitUntilExit()
    let codeText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let status = Int(codeText) ?? 0
    let body = (try? Data(contentsOf: bodyFile)) ?? Data()
    if status == 0 {
        throw DBLPError.curl(errorText.isEmpty ? "没有收到响应。" : errorText)
    }
    return (status, body)
}

private func parseHits(_ data: Data) throws -> [DBLPHit] {
    let rootObject: Any
    do {
        rootObject = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw DBLPError.badResponse("DBLP 检索结果不是 JSON。")
    }
    guard let root = rootObject as? [String: Any] else {
        throw DBLPError.badResponse("DBLP 检索结果不是 JSON。")
    }
    guard let result = root["result"] as? [String: Any] else {
        throw DBLPError.badResponse("DBLP 检索结果缺少 result。")
    }
    let hits = (result["hits"] as? [String: Any])?["hit"]
    return dictList(hits).compactMap(parseHit)
}

private func parseHit(_ hit: [String: Any]) -> DBLPHit? {
    let info = hit["info"] as? [String: Any] ?? [:]
    let title = cleanHTML(asString(info["title"]))
    guard !title.isEmpty else { return nil }
    let authors = authorList(info["authors"])
    return DBLPHit(
        title: title,
        year: asString(info["year"]),
        venue: cleanHTML(asString(info["venue"])),
        type: asString(info["type"]),
        key: asString(info["key"]),
        authors: authors,
        recordURL: asString(info["url"])
    )
}

private func authorList(_ value: Any?) -> [String] {
    guard let wrapper = value as? [String: Any] else { return [] }
    let author = wrapper["author"]
    if let list = author as? [[String: Any]] {
        return list.compactMap { $0["text"] as? String }
    }
    if let one = author as? [String: Any], let text = one["text"] as? String { return [text] }
    if let text = author as? String { return [text] }
    return []
}

private func dictList(_ value: Any?) -> [[String: Any]] {
    if let list = value as? [[String: Any]] { return list }
    if let one = value as? [String: Any] { return [one] }
    return []
}

private func asString(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

private func cleanHTML(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
        value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
    }
    return value.split { $0.isWhitespace }.joined(separator: " ")
}

func preferExactHit(_ hits: [DBLPHit]) -> DBLPHit? {
    hits.max { lhs, rhs in
        let left = venueRank(lhs)
        let right = venueRank(rhs)
        if left != right { return left < right }
        return (Int(lhs.year) ?? 0) < (Int(rhs.year) ?? 0)
    }
}

private func venueRank(_ hit: DBLPHit) -> Int {
    let venue = hit.venue.lowercased()
    let type = hit.type.lowercased()
    if venue == "corr" || type.contains("informal") { return 1 }
    if type.contains("journal") || type.contains("conference") { return 3 }
    return 2
}

func dblpRecordURL(from biburl: String) -> URL? {
    let text = latexToPlain(biburl).replacingOccurrences(of: " ", with: "")
    guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
    guard host == "dblp.org" || host.hasSuffix(".dblp.org") || host == "dblp.uni-trier.de" else { return nil }
    guard url.path.contains("/rec/") else { return nil }
    if url.path.hasSuffix(".bib") { return url }
    return URL(string: url.absoluteString + ".bib")
}
