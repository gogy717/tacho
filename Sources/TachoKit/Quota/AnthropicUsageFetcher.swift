import Foundation
import os

/// All the fetcher takes from Claude Code's sign-in: nothing else in the item is read, which is what the user is promised.
public struct ClaudeToken: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// `claudeAiOauth` of the Keychain item. nil without a token and its expiry, or with a token no header can carry.
    public static func parse(_ json: Data) -> ClaudeToken? {
        guard
            let oauth = JSONObject(json)?.object("claudeAiOauth"),
            let accessToken = oauth.string("accessToken"),
            !accessToken.isEmpty,
            accessToken.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
            let expiresAt = oauth.date("expiresAt")
        else { return nil }
        return ClaudeToken(accessToken: accessToken, expiresAt: expiresAt)
    }
}

/// What one fetch came to.
public enum FetchOutcome: Equatable, Sendable {
    case snapshots([QuotaSnapshot])
    /// No quota this time, and why, in words that never quote a token or a request.
    case skipped(String)
    /// Rate limited: nothing is sent before this time.
    case backoff(until: Date)
}

/// The one request Tacho may make, when the user turns it on: Anthropic's usage endpoint, with Claude Code's own sign-in, so the
/// quota stays fresh without `/usage` being run.
///
/// The token goes to `url` and nowhere else, and is neither logged nor kept between requests. It is never refreshed: that rotates
/// it and could sign Claude Code out, so an expiring token waits for Claude Code to refresh it.
public final class AnthropicUsageFetcher: Sendable {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// A token this close to expiry could lapse mid-request.
    private static let expiryMargin: TimeInterval = 60
    /// How long to wait after a 429 that does not say: the fetch interval.
    private static let defaultBackoff: TimeInterval = 300
    private static let requestTimeout: TimeInterval = 10
    private static let keychainTimeout: TimeInterval = 10

    private let token: @Sendable () throws -> ClaudeToken?
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let now: @Sendable () -> Date
    private let backoffUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// - Parameters:
    ///   - token: `keychainToken` in the app.
    ///   - send: `send(_:)` in the app.
    public init(
        token: @escaping @Sendable () throws -> ClaudeToken?,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.token = token
        self.send = send
        self.now = now
    }

    public func fetch() async -> FetchOutcome {
        if let until = backoffUntil.withLock({ $0 }), now() < until {
            return .skipped("rate limited")
        }
        let token: ClaudeToken
        do {
            guard let found = try self.token() else { return .skipped("not signed in to Claude") }
            token = found
        } catch {
            return .skipped("the sign-in cannot be read")
        }
        guard token.expiresAt >= now().addingTimeInterval(Self.expiryMargin) else {
            return .skipped("the sign-in has expired; Claude Code renews it on its next request")
        }

        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Data
        let response: HTTPURLResponse
        do {
            (body, response) = try await send(request)
        } catch {
            // The error's own text could quote the request, so it is not repeated.
            return .skipped("the request failed")
        }
        if response.statusCode == 429 {
            return backOff(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        guard response.statusCode == 200 else {
            return .skipped("the usage endpoint answered HTTP \(response.statusCode)")
        }
        // An error envelope parses too, as a quota with no windows.
        let snapshots = JSONObject(body).map {
            ClaudeUsageParser.snapshots($0, observedAt: now(), origin: .anthropicAPI, plan: nil)
        } ?? []
        return snapshots.isEmpty ? .skipped("the usage endpoint answered in an unknown format") : .snapshots(snapshots)
    }

    private func backOff(retryAfter: String?) -> FetchOutcome {
        let answered = now()
        let seconds = retryAfter.flatMap { Self.wait(retryAfter: $0, now: answered) } ?? Self.defaultBackoff
        let until = answered.addingTimeInterval(seconds)
        backoffUntil.withLock { $0 = until }
        return .backoff(until: until)
    }

    /// How long `Retry-After` says to wait: a number of seconds, or an HTTP date. nil when it says nothing usable, such as a negative
    /// number or a date already past.
    private static func wait(retryAfter value: String, now: Date) -> TimeInterval? {
        let seconds = TimeInterval(value) ?? httpDate(value).map { $0.timeIntervalSince(now) }
        return seconds.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// An HTTP date in any of the three forms RFC 9110 has a recipient accept: IMF-fixdate, then the obsolete RFC 850 and asctime.
    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: The real token and request

    /// Claude Code's sign-in from the Keychain; nil when there is none. macOS may ask the user to allow it.
    public static func keychainToken() throws -> ClaudeToken? {
        try commandOutput(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: keychainTimeout
        ).flatMap(ClaudeToken.parse)
    }

    /// What `path` printed; nil when it failed or ran past `timeout`. Its errors are dropped, not passed on to Tacho's own.
    static func commandOutput(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let pid = process.processIdentifier
        let deadline = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Read first: a command that fills the pipe never ends while nobody reads it.
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        deadline.cancel()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? printed : nil
    }

    /// Sends `request` over a session that follows no redirect, so the token reaches `url`'s host and no other, and keeps nothing.
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, configuration: sessionConfiguration)
    }

    static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return configuration
    }

    static func send(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (body, response)
    }
}

/// Answers every redirect with no: the redirect itself becomes the response.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
