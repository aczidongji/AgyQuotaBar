import AppKit
import CoreText
import Foundation

// MARK: - Models

struct QuotaSummaryResponse: Decodable {
    let groups: [QuotaGroup]?
}

struct QuotaGroup: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [QuotaBucket]?
}

struct QuotaBucket: Decodable {
    let bucketId: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
}

struct LoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

struct KeychainPayload: Decodable {
    let token: StoredToken?
    let idTokenEmail: String?

    enum CodingKeys: String, CodingKey {
        case token
        case idTokenEmail = "id_token_email"
    }
}

struct StoredToken: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiry: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiry
    }
}

struct RefreshTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

struct QuotaSnapshot {
    let gemini5h: QuotaBucket?
    let geminiWeekly: QuotaBucket?
    let claude5h: QuotaBucket?
    let claudeWeekly: QuotaBucket?
    let accountEmail: String?
    let fetchedAt: Date
}

// MARK: - OAuth Client Config
//
// No OAuth client credentials are shipped in this repository.
// By default the app only uses the access token that `agy` keeps fresh in the Keychain.
// If you want the app to refresh tokens by itself, provide your own client via:
//   1. Environment variables AGY_OAUTH_CLIENT_ID / AGY_OAUTH_CLIENT_SECRET
//   2. ~/.config/agyquotabar/oauth.json  ({"client_id": "...", "client_secret": "..."})

struct OAuthClientConfig: Codable {
    let clientId: String
    let clientSecret: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

enum OAuthClientStore {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agyquotabar/oauth.json")
    }

    static func loadConfigured() -> OAuthClientConfig? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["AGY_OAUTH_CLIENT_ID"], let secret = env["AGY_OAUTH_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty {
            return OAuthClientConfig(clientId: id, clientSecret: secret)
        }
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(OAuthClientConfig.self, from: data),
              !cfg.clientId.isEmpty, !cfg.clientSecret.isEmpty else {
            return nil
        }
        return cfg
    }
}

// MARK: - Quota Client

actor QuotaClient {
    private var oauthClient: OAuthClientConfig?
    private let quotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private let loadCodeAssistURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let userAgent = "antigravity/3.0.0 darwin/amd64"

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedExpiry: Date?
    private var cachedEmail: String?
    private var cachedProject: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func fetchQuota() async throws -> QuotaSnapshot {
        let token = try await validAccessToken(forceRefresh: false)
        do {
            return try await performFetch(accessToken: token)
        } catch QuotaError.unauthorized {
            // Token may have been revoked or rotated; reload Keychain and force refresh once.
            reloadFromKeychainIfNeeded(force: true)
            let fresh = try await validAccessToken(forceRefresh: true)
            return try await performFetch(accessToken: fresh)
        }
    }

    private func performFetch(accessToken: String) async throws -> QuotaSnapshot {
        let project = try await resolveProject(accessToken: accessToken)
        var req = URLRequest(url: quotaURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.network("无效响应")
        }
        if http.statusCode == 401 {
            throw QuotaError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError.http(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(QuotaSummaryResponse.self, from: data)
        let groups = decoded.groups ?? []

        var gemini5h: QuotaBucket?
        var geminiWeekly: QuotaBucket?
        var claude5h: QuotaBucket?
        var claudeWeekly: QuotaBucket?

        for group in groups {
            let name = (group.displayName ?? "").lowercased()
            let buckets = group.buckets ?? []
            if name.contains("gemini") {
                for b in buckets {
                    if b.bucketId == "gemini-5h" || b.window == "5h" { gemini5h = b }
                    if b.bucketId == "gemini-weekly" || b.window == "weekly" { geminiWeekly = b }
                }
            } else if name.contains("claude") || name.contains("3p") {
                for b in buckets {
                    if b.bucketId == "3p-5h" || b.window == "5h" { claude5h = b }
                    if b.bucketId == "3p-weekly" || b.window == "weekly" { claudeWeekly = b }
                }
            }
        }

        return QuotaSnapshot(
            gemini5h: gemini5h,
            geminiWeekly: geminiWeekly,
            claude5h: claude5h,
            claudeWeekly: claudeWeekly,
            accountEmail: cachedEmail,
            fetchedAt: Date()
        )
    }

    private func resolveProject(accessToken: String) async throws -> String {
        if let cachedProject, !cachedProject.isEmpty {
            return cachedProject
        }
        var req = URLRequest(url: loadCodeAssistURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw QuotaError.unauthorized }
            if (200..<300).contains(http.statusCode),
               let parsed = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data),
               let proj = parsed.cloudaicompanionProject, !proj.isEmpty {
                cachedProject = proj
                return proj
            }
        }
        return "aicode-consumers"
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        if cachedAccessToken == nil {
            reloadFromKeychainIfNeeded(force: true)
        }

        func stillValid() -> Bool {
            guard let expiry = cachedExpiry else { return cachedAccessToken != nil }
            return expiry.timeIntervalSinceNow > 120
        }

        if !forceRefresh, let token = cachedAccessToken, stillValid() {
            return token
        }

        // Token is stale: agy may have refreshed the Keychain entry in the meantime.
        reloadFromKeychainIfNeeded(force: true)
        if let token = cachedAccessToken, stillValid() {
            return token
        }

        // Optional self-refresh, only when the user supplied their own OAuth client.
        if let refreshToken = cachedRefreshToken, !refreshToken.isEmpty,
           OAuthClientStore.loadConfigured() != nil {
            return try await refreshAccessToken(refreshToken: refreshToken)
        }
        if cachedAccessToken == nil { throw QuotaError.missingCredentials }
        throw QuotaError.missingOAuthClient
    }

    private enum RefreshResult {
        case success(RefreshTokenResponse)
        case failure(Int, String)
    }

    private func requestRefresh(refreshToken: String, client: OAuthClientConfig) async throws -> RefreshResult {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return .failure(code, String(data: data, encoding: .utf8) ?? "")
        }
        return .success(try JSONDecoder().decode(RefreshTokenResponse.self, from: data))
    }

    private func applyRefreshed(_ refreshed: RefreshTokenResponse) -> String {
        cachedAccessToken = refreshed.accessToken
        cachedExpiry = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn ?? 3500))
        return refreshed.accessToken
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        if oauthClient == nil {
            oauthClient = OAuthClientStore.loadConfigured()
        }
        if let client = oauthClient {
            switch try await requestRefresh(refreshToken: refreshToken, client: client) {
            case .success(let refreshed):
                return applyRefreshed(refreshed)
            case .failure(let code, let body):
                throw QuotaError.authRefresh("HTTP \(code): \(body)")
            }
        }

        throw QuotaError.missingOAuthClient
    }

    private func reloadFromKeychainIfNeeded(force: Bool) {
        if !force && cachedAccessToken != nil { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return
        }
        guard proc.terminationStatus == 0 else { return }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "go-keyring-base64:"
        guard raw.hasPrefix(prefix) else { return }

        var b64 = String(raw.dropFirst(prefix.count))
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        guard let jsonData = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(KeychainPayload.self, from: jsonData),
              let tok = payload.token else {
            return
        }

        cachedAccessToken = tok.accessToken
        cachedRefreshToken = tok.refreshToken
        cachedEmail = payload.idTokenEmail
        if let expStr = tok.expiry {
            cachedExpiry = DateParser.parse(expStr)
        }
    }
}

enum QuotaError: LocalizedError {
    case missingCredentials
    case unauthorized
    case network(String)
    case http(Int, String)
    case authRefresh(String)
    case missingOAuthClient

    var errorDescription: String? {
        switch self {
        case .missingOAuthClient:
            return "登录令牌已过期：请运行一次 agy 刷新（或按 README 配置自己的 OAuth Client）"
        case .missingCredentials:
            return "未找到 Keychain 中的 agy 登录凭证（请先运行 agy 登录）"
        case .unauthorized:
            return "凭证已失效（HTTP 401）"
        case .network(let msg):
            return "网络错误：\(msg)"
        case .http(let code, let msg):
            return "接口错误 HTTP \(code)：\(msg.prefix(120))"
        case .authRefresh(let msg):
            return "刷新 Token 失败：\(msg.prefix(120))"
        }
    }
}

// MARK: - Date & Formatting Helpers

enum DateParser {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        return withFractional.date(from: str) ?? plain.date(from: str)
    }
}

enum QuotaFormatter {
    private static let sameDayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let fullTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let updateClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func numberString(_ bucket: QuotaBucket?) -> String {
        guard let frac = bucket?.remainingFraction else { return "--" }
        let pct = max(0, min(100, Int((frac * 100.0).rounded())))
        return "\(pct)"
    }

    static func percentString(_ bucket: QuotaBucket?) -> String {
        guard let frac = bucket?.remainingFraction else { return "--%" }
        let pct = max(0, min(100, Int((frac * 100.0).rounded())))
        return "\(pct)%"
    }

    static func detailLine(label: String, bucket: QuotaBucket?, now: Date = Date()) -> String {
        let pct = percentString(bucket)
        guard let bucket else {
            return "\(label)：\(pct)"
        }
        guard let resetDate = DateParser.parse(bucket.resetTime) else {
            return "\(label)：\(pct)"
        }
        let countdown = formatCountdown(to: resetDate, from: now)
        let localReset = Calendar.current.isDate(resetDate, inSameDayAs: now)
            ? sameDayTimeFormatter.string(from: resetDate)
            : fullTimeFormatter.string(from: resetDate)
        return "\(label)：\(pct)（\(countdown) · \(localReset)）"
    }

    static func formatCountdown(to target: Date, from now: Date) -> String {
        let diff = Int(target.timeIntervalSince(now))
        if diff <= 0 {
            return "即将重置"
        }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 {
            return "\(days)天\(hours)小时后重置"
        }
        if hours > 0 {
            return "\(hours)小时\(mins)分钟后重置"
        }
        return "\(max(1, mins))分钟后重置"
    }

    static func formatClock(_ date: Date) -> String {
        updateClockFormatter.string(from: date)
    }
}

enum AppLogger {
    private static let retentionSeconds: TimeInterval = 3 * 24 * 60 * 60
    private static let pruneIntervalSeconds: TimeInterval = 60 * 60
    private static let queue = DispatchQueue(label: "io.github.aczidongji.AgyQuotaBar.logger")
    private static var lastPruneDate: Date?

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AgyQuotaBar.log")
    }

    static func pruneOldLogsIfNeeded() {
        queue.async {
            pruneLocked(now: Date(), force: true)
        }
    }

    static func log(_ message: String) {
        queue.async {
            let now = Date()
            let ts = logDateFormatter.string(from: now)
            let line = "[\(ts)] \(message)\n"
            if let data = line.data(using: .utf8) {
                let fm = FileManager.default
                if !fm.fileExists(atPath: logURL.path) {
                    try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    fm.createFile(atPath: logURL.path, contents: data)
                } else if let handle = try? FileHandle(forWritingTo: logURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            }
            pruneLocked(now: now, force: false)
        }
    }

    private static func parseLogDate(from line: Substring) -> Date? {
        guard line.hasPrefix("["), line.count >= 21 else { return nil }
        let endIdx = line.index(line.startIndex, offsetBy: 20)
        guard line[endIdx] == "]" else { return nil }
        let startIdx = line.index(after: line.startIndex)
        return logDateFormatter.date(from: String(line[startIdx..<endIdx]))
    }

    private static func pruneLocked(now: Date, force: Bool) {
        if !force, let lastPruneDate, now.timeIntervalSince(lastPruneDate) < pruneIntervalSeconds {
            return
        }
        lastPruneDate = now

        guard let content = try? String(contentsOf: logURL, encoding: .utf8), !content.isEmpty else {
            return
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let cutoff = now.addingTimeInterval(-retentionSeconds)

        var lastExpiredIndex: Int?
        for (index, line) in lines.enumerated() {
            if let date = parseLogDate(from: line), date < cutoff {
                lastExpiredIndex = index
            }
        }
        guard let dropIndex = lastExpiredIndex else { return }

        var keepStart = dropIndex + 1
        while keepStart < lines.count && !lines[keepStart].hasPrefix("[") {
            keepStart += 1
        }

        let kept = lines[keepStart...].filter { !$0.isEmpty }
        let updatedText = kept.isEmpty ? "" : (kept.joined(separator: "\n") + "\n")
        if let data = updatedText.data(using: .utf8) {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

// MARK: - LaunchAgent Helper

enum LaunchAgentManager {
    private static let label = "io.github.aczidongji.AgyQuotaBar"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let dir = plistURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let execPath = Bundle.main.executablePath else { return }
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let client = QuotaClient()

    private let fastPollInterval: TimeInterval = 60
    private let slowPollInterval: TimeInterval = 300
    private let idleChecksBeforeSlow = 15

    private var timer: Timer?
    private var currentPollInterval: TimeInterval = 60
    private var unchangedFastChecks = 0
    private var latestSnapshot: QuotaSnapshot?
    private var latestError: String?
    private var isFetching = false

    private func makeStatusImage(_ left: String, _ right: String) -> NSImage {
        let digitFont = NSFont.systemFont(ofSize: 14.5, weight: .regular)
        let pipeFont = NSFont.systemFont(ofSize: 12.2, weight: .regular)

        let refLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "82", attributes: [.font: digitFont])
        )
        let leftLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: left, attributes: [.font: digitFont, .foregroundColor: NSColor.black])
        )
        let pipeLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "|", attributes: [.font: pipeFont, .foregroundColor: NSColor.black])
        )
        let rightLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: right, attributes: [.font: digitFont, .foregroundColor: NSColor.black])
        )

        let refBounds = CTLineGetBoundsWithOptions(refLine, .useGlyphPathBounds)
        let lb = CTLineGetBoundsWithOptions(leftLine, .useGlyphPathBounds)
        let pb = CTLineGetBoundsWithOptions(pipeLine, .useGlyphPathBounds)
        let rb = CTLineGetBoundsWithOptions(rightLine, .useGlyphPathBounds)

        let height = max(22.0, NSStatusBar.system.thickness)
        let gap: CGFloat = 3.5
        let padX: CGFloat = 1.0
        let totalWidth = ceil(padX + lb.width + gap + pb.width + gap + rb.width + padX)

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            let digitBaseY = rect.midY - refBounds.midY
            let pipeBaseY = rect.midY - pb.midY

            ctx.textPosition = CGPoint(x: padX - lb.origin.x, y: digitBaseY)
            CTLineDraw(leftLine, ctx)

            ctx.textPosition = CGPoint(x: padX + lb.width + gap - pb.origin.x, y: pipeBaseY)
            CTLineDraw(pipeLine, ctx)

            ctx.textPosition = CGPoint(x: padX + lb.width + gap + pb.width + gap - rb.origin.x, y: digitBaseY)
            CTLineDraw(rightLine, ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func applyStatusDisplay(_ left: String, _ right: String) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = makeStatusImage(left, right)
        button.setAccessibilityLabel("\(left) | \(right)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusDisplay("--", "--")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        AppLogger.pruneOldLogsIfNeeded()
        scheduleTimer(interval: fastPollInterval)
        refreshQuota()
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentPollInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let appDelegate = self else { return }
            DispatchQueue.main.async {
                appDelegate.refreshQuota()
            }
        }
    }

    @objc private func handleWake() {
        scheduleTimer(interval: currentPollInterval)
        refreshQuota()
    }

    @objc private func manualRefresh() {
        scheduleTimer(interval: currentPollInterval)
        refreshQuota()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgentManager.setEnabled(!LaunchAgentManager.isEnabled)
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func bucketFractionChanged(_ lhs: QuotaBucket?, _ rhs: QuotaBucket?) -> Bool {
        switch (lhs?.remainingFraction, rhs?.remainingFraction) {
        case (nil, nil):
            return false
        case let (a?, b?):
            return abs(a - b) > 1e-6
        default:
            return true
        }
    }

    private func hasQuotaChanged(from old: QuotaSnapshot, to new: QuotaSnapshot) -> Bool {
        bucketFractionChanged(old.gemini5h, new.gemini5h)
            || bucketFractionChanged(old.geminiWeekly, new.geminiWeekly)
            || bucketFractionChanged(old.claude5h, new.claude5h)
            || bucketFractionChanged(old.claudeWeekly, new.claudeWeekly)
    }

    private func updatePollingCadence(with newSnapshot: QuotaSnapshot) -> String {
        guard let previous = latestSnapshot else {
            unchangedFastChecks = 0
            if currentPollInterval != fastPollInterval {
                scheduleTimer(interval: fastPollInterval)
            }
            return "poll=1m(init)"
        }

        if hasQuotaChanged(from: previous, to: newSnapshot) {
            unchangedFastChecks = 0
            if currentPollInterval != fastPollInterval {
                scheduleTimer(interval: fastPollInterval)
                return "poll=5m->1m(changed)"
            }
            return "poll=1m(changed)"
        }

        if currentPollInterval == fastPollInterval {
            unchangedFastChecks += 1
            if unchangedFastChecks >= idleChecksBeforeSlow {
                scheduleTimer(interval: slowPollInterval)
                return "poll=1m->5m(idle=\(unchangedFastChecks)/\(idleChecksBeforeSlow))"
            }
            return "poll=1m(idle=\(unchangedFastChecks)/\(idleChecksBeforeSlow))"
        }

        return "poll=5m(idle)"
    }

    private func refreshQuota() {
        guard !isFetching else { return }
        isFetching = true
        let client = self.client
        Task {
            do {
                let snap = try await client.fetchQuota()
                let g5h = QuotaFormatter.numberString(snap.gemini5h)
                let gwk = QuotaFormatter.numberString(snap.geminiWeekly)
                await MainActor.run {
                    let pollState = self.updatePollingCadence(with: snap)
                    AppLogger.log("OK title=\(g5h)|\(gwk) claude5h=\(QuotaFormatter.percentString(snap.claude5h)) claudeWk=\(QuotaFormatter.percentString(snap.claudeWeekly)) \(pollState)")
                    self.latestSnapshot = snap
                    self.latestError = nil
                    self.isFetching = false
                    self.updateStatusTitle()
                    self.rebuildMenu()
                }
            } catch {
                AppLogger.log("ERR \(error.localizedDescription)")
                await MainActor.run {
                    self.latestError = error.localizedDescription
                    self.isFetching = false
                    self.updateStatusTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func updateStatusTitle() {
        if let snap = latestSnapshot {
            let g5h = QuotaFormatter.numberString(snap.gemini5h)
            let gwk = QuotaFormatter.numberString(snap.geminiWeekly)
            applyStatusDisplay(g5h, gwk)
        } else if latestError != nil {
            applyStatusDisplay("ERR", "ERR")
        } else {
            applyStatusDisplay("--", "--")
        }
    }

    private func makeInfoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold
            ? NSFont.systemFont(ofSize: 12, weight: .semibold)
            : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 21),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        let fitting = container.fittingSize
        container.frame = NSRect(origin: .zero, size: fitting)
        container.translatesAutoresizingMaskIntoConstraints = true
        item.view = container
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()

        if let snap = latestSnapshot {
            menu.addItem(makeInfoItem("Gemini Models", bold: true))
            menu.addItem(makeInfoItem(QuotaFormatter.detailLine(label: "5小时窗口", bucket: snap.gemini5h, now: now)))
            menu.addItem(makeInfoItem(QuotaFormatter.detailLine(label: "每周额度", bucket: snap.geminiWeekly, now: now)))

            menu.addItem(.separator())

            menu.addItem(makeInfoItem("Claude & GPT Models", bold: true))
            menu.addItem(makeInfoItem(QuotaFormatter.detailLine(label: "5小时窗口", bucket: snap.claude5h, now: now)))
            menu.addItem(makeInfoItem(QuotaFormatter.detailLine(label: "每周额度", bucket: snap.claudeWeekly, now: now)))

            menu.addItem(.separator())

            let updatedStr = QuotaFormatter.formatClock(snap.fetchedAt)
            let accountSuffix = snap.accountEmail.map { " · \($0)" } ?? ""
            menu.addItem(makeInfoItem("更新于 \(updatedStr)\(accountSuffix)"))
        } else {
            menu.addItem(makeInfoItem(isFetching ? "正在获取额度..." : "暂无额度数据"))
        }

        if let err = latestError {
            menu.addItem(makeInfoItem("错误：\(err)"))
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: isFetching ? "刷新中..." : "立即刷新", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isFetching
        menu.addItem(refreshItem)

        let launchItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAgentManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
