import Foundation

struct EndpointResponse: Sendable {
    var status: Int
    var body: Data
    var retryAfter: TimeInterval?
}

/// Anthropic's usage endpoint, as the optional fallback asks it.
protocol ClaudeUsageEndpoint: Sendable {
    func fetchUsage(accessToken: String) async throws -> EndpointResponse
}

/// The only code in Brim that talks to a machine other than this Mac, and only
/// ever to one URL. Unused unless "Refresh while Claude Code is closed" is on.
///
/// A request carries Claude Code's access token and nothing else of the user's:
/// no cookies, no cache, no proxy, and no redirect is followed, so the token
/// cannot be carried anywhere but this URL. Nothing about a request or its
/// answer is logged, and the answer is parsed and dropped.
struct AnthropicUsageClient: ClaudeUsageEndpoint {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Brim", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return configuration
    }

    func fetchUsage(accessToken: String) async throws -> EndpointResponse {
        // A session per request: the calls are minutes apart, and nothing
        // lingers between them.
        let session = URLSession(configuration: Self.configuration(), delegate: RedirectRefuser(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: Self.request(accessToken: accessToken))
        guard let http = response as? HTTPURLResponse, http.url?.host == Self.endpoint.host else {
            throw URLError(.badServerResponse)
        }
        return EndpointResponse(status: http.statusCode, body: data,
                                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }

    final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
