import Foundation

/// The only code in Brim that opens a network connection, and it can only
/// reach this Mac.
///
/// Requests are built here from a port and a path — callers cannot pass a URL —
/// and the host is always 127.0.0.1. The path must be on the calling adapter's
/// allowlist. The session keeps nothing: no cookies, no cache, no credential
/// store, no proxy, and redirects are refused, so a local server cannot bounce
/// a request anywhere else.
public final class LoopbackHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public enum RequestError: Error, Equatable {
        case notAllowlisted
        case connectionRefused
        case timedOut
        case badStatus(Int)
        case tooLarge
        case unreachable
    }

    /// What one adapter may ask for.
    public struct Allowlist: Sendable {
        public let paths: Set<String>
        public init(paths: [String]) { self.paths = Set(paths) }
    }

    public static let host = "127.0.0.1"
    public let maxResponseBytes: Int

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: false,
                                            kCFNetworkProxiesHTTPSEnable as String: false]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Brim-local"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 3, maxResponseBytes: Int = 2 << 20) {
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }

    /// The URL a request would go to, or nil if it is not allowed. Exposed for
    /// the tests that pin the rules.
    public static func url(port: Int, path: String, allowlist: Allowlist) -> URL? {
        guard (1...65535).contains(port), allowlist.paths.contains(path) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url, isLoopback(url) else { return nil }
        return url
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    public func get(port: Int, path: String, allowlist: Allowlist) async throws -> Data {
        guard let url = Self.url(port: port, path: path, allowlist: allowlist) else {
            throw RequestError.notAllowlisted
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RequestError.unreachable }
            guard (200..<300).contains(http.statusCode) else { throw RequestError.badStatus(http.statusCode) }
            guard data.count <= maxResponseBytes else { throw RequestError.tooLarge }
            return data
        } catch let error as RequestError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                throw RequestError.connectionRefused
            case .timedOut:
                throw RequestError.timedOut
            default:
                throw RequestError.unreachable
            }
        } catch {
            throw RequestError.unreachable
        }
    }

    // A local server has no business sending Brim elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
