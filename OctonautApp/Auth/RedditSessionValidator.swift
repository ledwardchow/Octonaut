import Foundation

struct RedditIdentity: Sendable, Equatable {
    let username: String
    let userID: String?
    let modhash: String
}

enum RedditLoginError: Error, LocalizedError, Sendable, Equatable {
    case missingSessionCookie
    case invalidIdentity
    case rejected(status: Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingSessionCookie: return "Reddit did not provide a session cookie yet. Finish signing in on the Reddit page."
        case .invalidIdentity: return "Reddit login did not return a valid account identity."
        case .rejected(let status): return "Reddit rejected the login check (HTTP \(status))."
        case .network(let message): return message
        }
    }
}

actor RedditSessionValidator {
    private let session: URLSession
    private let identityURL = URL(string: "https://www.reddit.com/user/me/about.json?raw_json=1")!

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: RedditLoginRedirectDelegate(), delegateQueue: nil)
    }

    func validate(
        cookieName: String,
        cookieValue: String,
        companionCookies: [String: String] = [:]
    ) async throws -> RedditIdentity {
        guard !cookieName.isEmpty, !cookieValue.isEmpty else { throw RedditLoginError.missingSessionCookie }
        var request = URLRequest(url: identityURL)
        request.httpMethod = "GET"
        var cookies = companionCookies
        cookies[cookieName] = cookieValue
        let cookieHeader = cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RedditLoginError.network("Reddit login could not be checked. Try again when you are online.")
        }
        guard let http = response as? HTTPURLResponse else { throw RedditLoginError.invalidIdentity }
        guard (200..<300).contains(http.statusCode) else { throw RedditLoginError.rejected(status: http.statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let username = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty,
              let modhash = (payload["modhash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modhash.isEmpty else {
            throw RedditLoginError.invalidIdentity
        }
        return RedditIdentity(username: username, userID: payload["id"] as? String, modhash: modhash)
    }
}

private final class RedditLoginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String> = ["www.reddit.com", "reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
