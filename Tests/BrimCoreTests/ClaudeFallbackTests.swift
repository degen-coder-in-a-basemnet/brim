import Foundation
import Security
@testable import BrimCore

/// A keychain that is never the real one: no test may touch the login keychain.
final class StubCredentialStore: ClaudeCredentialStore, @unchecked Sendable {
    var result: Result<ClaudeOAuthCredential, ClaudeCredentialError>
    private(set) var reads = 0

    init(_ result: Result<ClaudeOAuthCredential, ClaudeCredentialError>) { self.result = result }

    func read() throws -> ClaudeOAuthCredential {
        reads += 1
        return try result.get()
    }
}

/// Anthropic, played by a list of answers; the last one repeats. Records every
/// token it is sent.
final class StubUsageEndpoint: ClaudeUsageEndpoint, @unchecked Sendable {
    var answers: [EndpointResponse]
    private(set) var tokens: [String] = []

    init(_ answers: [EndpointResponse]) { self.answers = answers }

    func fetchUsage(accessToken: String) async throws -> EndpointResponse {
        tokens.append(accessToken)
        guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// Canary credentials: shaped like Claude Code's, and never allowed to surface.
enum FallbackFixtures {
    static let token = "sk-ant-oat01-CANARYACCESSTOKEN0123456789abcdef"
    static let refresh = "sk-ant-ort01-CANARYREFRESHTOKEN0123456789abcdef"

    static func keychainItem(expiresAt: Date, accessToken: String = token) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refresh)","expiresAt":\#(millis),"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}"#.utf8)
    }

    static func credential(expiresAt: Date) -> ClaudeOAuthCredential {
        try! ClaudeOAuthCredential.decode(keychainItem(expiresAt: expiresAt))
    }

    static func usage(session: Date = date("2026-09-25T03:19:59Z"), weekly: Date = date("2026-10-01T02:59:59Z")) -> EndpointResponse {
        let iso = ISO8601DateFormatter()
        return EndpointResponse(status: 200, body: Data(#"{"five_hour":{"utilization":24.0,"resets_at":"\#(iso.string(from: session))"},"seven_day":{"utilization":30.0,"resets_at":"\#(iso.string(from: weekly))"},"seven_day_opus":null,"extra_usage":{"is_enabled":false}}"#.utf8))
    }

    /// What the status-line snippet writes.
    static func handoff(updatedAt: Date, session: Double = 24, weekly: Double = 30) -> String {
        let at = updatedAt.timeIntervalSince1970
        return #"{"version":1,"updated_at":\#(at),"five_hour":{"used_percentage":\#(session),"resets_at":\#(Int(at) + 17_000)},"seven_day":{"used_percentage":\#(weekly),"resets_at":\#(Int(at) + 500_000)}}"#
    }

    static func environment(_ root: URL, lastResponse: Date) -> ProviderEnvironment {
        let environment = ProviderEnvironment(home: root, applicationSupport: root.appendingPathComponent("Support"))
        let stamp = ISO8601DateFormatter().string(from: lastResponse)
        write(ClaudeFixtures.assistant(id: "a", request: "1", at: stamp, input: 1000, output: 0) + "\n",
              to: environment.claudeDirectory.appendingPathComponent("projects/-Users-me-brim/s1.jsonl"))
        return environment
    }
}

enum ClaudeHandoffTests {
    typealias X = FallbackFixtures
    static let now = date("2026-09-24T22:29:00Z")

    static let suite = TestSuite("Claude status-line handoff", [
        test("reads the percentages and resets the status line was handed") {
            let reading = ClaudeStatuslineHandoff.reading(from: Data(X.handoff(updatedAt: now).utf8))
            expectEqual(reading?.origin, .statusline)
            expectEqual(reading?.at, now)
            expectApprox(reading?.windows["session"]?.fraction, 0.24)
            expectApprox(reading?.windows["weekly_all"]?.fraction, 0.30)
            expectEqual(reading?.windows["session"]?.resetsAt, now.addingTimeInterval(17_000))
        },
        test("ISO resets are read too; nonsense and missing pieces are not") {
            let iso = #"{"updated_at":1790290000,"five_hour":{"used_percentage":140,"resets_at":"2026-09-25T03:19:59Z"}}"#
            let reading = ClaudeStatuslineHandoff.reading(from: Data(iso.utf8))
            expectApprox(reading?.windows["session"]?.fraction, 1)
            expectEqual(reading?.windows["session"]?.resetsAt, date("2026-09-25T03:19:59Z"))
            expectNil(reading?.windows["weekly_all"])
            expectNil(ClaudeStatuslineHandoff.reading(from: Data(#"{"five_hour":{"used_percentage":20}}"#.utf8)))
            expectNil(ClaudeStatuslineHandoff.reading(from: Data(#"{"updated_at":1790290000}"#.utf8)))
            expectNil(ClaudeStatuslineHandoff.reading(from: Data("not json".utf8)))
        },
        test("the snippet hands over percentages and reset times, nothing else") {
            let snippet = ClaudeStatuslineHandoff.nodeSnippet
            expect(snippet.contains("used_percentage: w.used_percentage, resets_at: w.resets_at"))
            expect(snippet.contains("'Application Support', 'Brim'") && snippet.contains("claude-statusline.json"))
            for field in ["transcript_path", "cwd", "session_id", "workspace", "cost", "model"] {
                expect(!snippet.contains(field), "the snippet mentions \(field)")
            }
        },
        test("a fresh handoff outranks an older cached figure") {
            await withTemporaryDirectory { root in
                let now = Date()
                let iso = ISO8601DateFormatter()
                let environment = X.environment(root, lastResponse: now.addingTimeInterval(-600))
                write(ClaudeConfigFixtures.config(fetchedAt: now.addingTimeInterval(-1200),
                                                  session: (51, iso.string(from: now.addingTimeInterval(3600))), weekly: nil),
                      to: environment.claudeConfigFile)
                write(X.handoff(updatedAt: now.addingTimeInterval(-60)),
                      to: ClaudeStatuslineHandoff.url(in: environment.applicationSupport))

                let provider = ClaudeCodeProvider(environment: environment, files: .standard(environment),
                                                  settings: ClaudeSettings(), showSessionTitles: false, calibration: nil,
                                                  credentials: StubCredentialStore(.failure(.notFound)),
                                                  endpoint: StubUsageEndpoint([]))
                let snapshot = await provider.fetchSnapshot(now: now)
                let session = snapshot.windows.first { $0.id == "session" }
                expectApprox(session?.usedFraction, 0.24)
                expectEqual(session?.fidelity, .official)
                expect(snapshot.source?.contains("status line") == true, snapshot.source ?? "no source")
                let status = await provider.sourceStatus()
                expectNotNil(status.statuslineReportedAt)
                expectEqual(status.fallback, .off)
            }
        },
    ])
}

enum ClaudeFallbackTests {
    typealias X = FallbackFixtures
    static let now = date("2026-09-24T22:29:00Z")
    /// Claude Code reported a minute ago: it is running.
    static let fresh = now.addingTimeInterval(-60)
    /// An hour ago: it is closed.
    static let stale = now.addingTimeInterval(-3600)

    static func make(_ keychain: Result<ClaudeOAuthCredential, ClaudeCredentialError>
                        = .success(X.credential(expiresAt: date("2026-09-25T06:00:00Z"))),
                     answers: [EndpointResponse] = [X.usage()])
        -> (ClaudeUsageFallback, StubCredentialStore, StubUsageEndpoint) {
        let store = StubCredentialStore(keychain)
        let endpoint = StubUsageEndpoint(answers)
        return (ClaudeUsageFallback(credentials: store, endpoint: endpoint), store, endpoint)
    }

    static let suite = TestSuite("Claude keychain fallback", [
        test("the credential keeps its token out of every description") {
            let credential = X.credential(expiresAt: now)
            expectEqual(credential.accessToken, X.token)
            expectEqual(credential.plan, "max")
            var dumped = ""
            dump(credential, to: &dumped)
            for text in [String(describing: credential), String(reflecting: credential), dumped, "\(credential)"] {
                expect(!text.contains(X.token) && !text.contains(X.refresh), "a description leaked the sign-in")
            }
        },
        test("an emptied sign-in reads as signed out, anything else as unreadable") {
            do {
                _ = try ClaudeOAuthCredential.decode(X.keychainItem(expiresAt: now, accessToken: ""))
                expect(false, "an empty token decoded")
            } catch {
                expectEqual(error as? ClaudeCredentialError, .signedOut)
            }
            do {
                _ = try ClaudeOAuthCredential.decode(Data("{}".utf8))
                expect(false, "an empty item decoded")
            } catch {
                expectEqual(error as? ClaudeCredentialError, .unreadable)
            }
        },
        test("a keychain refusal is told apart from a missing sign-in") {
            expectEqual(SystemClaudeKeychain.error(for: errSecItemNotFound), .notFound)
            for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
                expectEqual(SystemClaudeKeychain.error(for: status), .denied)
            }
            expectEqual(SystemClaudeKeychain.error(for: -25320), .notNow)
        },
        test("requests go to one URL, carrying only the token and the beta flag") {
            let request = AnthropicUsageClient.request(accessToken: X.token)
            expectEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            expectEqual(request.httpMethod, "GET")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(X.token)")
            expectEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            expect(!request.httpShouldHandleCookies)
            expectNil(request.httpBody)
            let configuration = AnthropicUsageClient.configuration()
            expectNil(configuration.urlCache)
            expectNil(configuration.httpCookieStorage)
            expectEqual(configuration.connectionProxyDictionary?.count, 0)
        },
        test("redirects are refused, so the token can't be carried elsewhere") {
            let elsewhere = URL(string: "https://example.com/")!
            let response = HTTPURLResponse(url: AnthropicUsageClient.endpoint, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": elsewhere.absoluteString])!
            var followed: URLRequest? = URLRequest(url: elsewhere)
            AnthropicUsageClient.RedirectRefuser().urlSession(
                URLSession.shared, task: URLSession.shared.dataTask(with: AnthropicUsageClient.endpoint),
                willPerformHTTPRedirection: response, newRequest: URLRequest(url: elsewhere)) { followed = $0 }
            expectNil(followed)
        },
        test("switched on but never clicked: no keychain read and no request") {
            let (fallback, keychain, endpoint) = make()
            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            expectEqual(fallback.state, .needsApproval)
            expectEqual(keychain.reads, 0)
            expectEqual(endpoint.tokens.count, 0)
        },
        test("after a click it stands by while Claude Code reports, and asks once it stops") {
            let (fallback, keychain, endpoint) = make()
            fallback.requestAccess(now: now)
            expectEqual(keychain.reads, 1)
            await fallback.poll(now: now, freshestLocal: fresh, interval: 600)
            expectEqual(fallback.state, .standingBy)
            expectEqual(endpoint.tokens.count, 0)

            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            expectEqual(endpoint.tokens, [X.token])
            expectEqual(fallback.state, .checked(now))
            expectEqual(fallback.reading?.origin, .endpoint)
            expectApprox(fallback.reading?.windows["session"]?.fraction, 0.24)
            expectEqual(fallback.reading?.plan, "Max")

            await fallback.poll(now: now.addingTimeInterval(120), freshestLocal: stale, interval: 600)
            expectEqual(endpoint.tokens.count, 1, "asked again inside the interval")
            expectEqual(keychain.reads, 1, "read the keychain on a timer")
        },
        test("a declined prompt stops everything until the next click") {
            let (fallback, keychain, endpoint) = make(.failure(.denied))
            fallback.requestAccess(now: now)
            expectEqual(fallback.state, .denied)
            expect(fallback.state.needsAccess)
            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            expectEqual(keychain.reads, 1)
            expectEqual(endpoint.tokens.count, 0)
        },
        test("an expired sign-in is never sent") {
            let (fallback, _, endpoint) = make(.success(X.credential(expiresAt: now.addingTimeInterval(-1))))
            fallback.requestAccess(now: now)
            expectEqual(fallback.state, .expired)
            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            expectEqual(endpoint.tokens.count, 0)
        },
        test("a sign-in that expires while held is dropped, not renewed") {
            let (fallback, keychain, endpoint) = make(.success(X.credential(expiresAt: now.addingTimeInterval(300))))
            fallback.requestAccess(now: now)
            await fallback.poll(now: now.addingTimeInterval(600), freshestLocal: stale, interval: 600)
            expectEqual(fallback.state, .expired)
            expectEqual(endpoint.tokens.count, 0)
            expectEqual(keychain.reads, 1)
        },
        test("a rotated token (401) is dropped, and the keychain is left alone") {
            let (fallback, keychain, endpoint) = make(answers: [EndpointResponse(status: 401, body: Data())])
            fallback.requestAccess(now: now)
            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            expectEqual(fallback.state, .expired)
            await fallback.poll(now: now.addingTimeInterval(3600), freshestLocal: stale, interval: 600)
            expectEqual(endpoint.tokens.count, 1)
            expectEqual(keychain.reads, 1)
        },
        test("rate limiting backs off for as long as Anthropic asks") {
            let (fallback, _, endpoint) = make(answers: [EndpointResponse(status: 429, body: Data(), retryAfter: 1800), X.usage()])
            fallback.requestAccess(now: now)
            await fallback.poll(now: now, freshestLocal: stale, interval: 300)
            expectEqual(fallback.state, .retrying(until: now.addingTimeInterval(1800), reason: "Anthropic asked Brim to slow down."))
            await fallback.poll(now: now.addingTimeInterval(900), freshestLocal: stale, interval: 300)
            expectEqual(endpoint.tokens.count, 1)
            await fallback.poll(now: now.addingTimeInterval(1801), freshestLocal: stale, interval: 300)
            expectEqual(endpoint.tokens.count, 2)
            expectEqual(fallback.state, .checked(now.addingTimeInterval(1801)))
        },
        test("switching off forgets the sign-in and what it fetched") {
            let (fallback, _, endpoint) = make()
            fallback.requestAccess(now: now)
            await fallback.poll(now: now, freshestLocal: stale, interval: 600)
            fallback.forget()
            expectEqual(fallback.state, .off)
            expectNil(fallback.reading)
            await fallback.poll(now: now.addingTimeInterval(3600), freshestLocal: stale, interval: 600)
            expectEqual(endpoint.tokens.count, 1)
        },
        test("the provider reads the keychain only when on and asked, and sends the token nowhere else") {
            await withTemporaryDirectory { root in
                let now = Date()
                let environment = X.environment(root, lastResponse: now.addingTimeInterval(-7200))
                let keychain = StubCredentialStore(.success(X.credential(expiresAt: now.addingTimeInterval(3600))))
                let endpoint = StubUsageEndpoint([X.usage(session: now.addingTimeInterval(9000),
                                                          weekly: now.addingTimeInterval(400_000))])
                var settings = ClaudeSettings()
                let provider = ClaudeCodeProvider(environment: environment, files: .standard(environment),
                                                  settings: settings, showSessionTitles: false, calibration: nil,
                                                  credentials: keychain, endpoint: endpoint)
                _ = await provider.fetchSnapshot(now: now)
                await provider.requestKeychainAccess(now: now)
                expectEqual(keychain.reads, 0, "read the keychain while switched off")
                expectEqual(endpoint.tokens.count, 0)

                settings.refreshWhileClosed = true
                await provider.update(settings: settings, showSessionTitles: false)
                let waiting = await provider.sourceStatus()
                expectEqual(waiting.fallback, .needsApproval)
                await provider.requestKeychainAccess(now: now)
                let snapshot = await provider.fetchSnapshot(now: now)
                expectEqual(keychain.reads, 1)
                expectEqual(endpoint.tokens, [X.token])
                let session = snapshot.windows.first { $0.id == "session" }
                expectApprox(session?.usedFraction, 0.24)
                expectEqual(session?.fidelity, .official)
                expectEqual(snapshot.plan, "Max")
                expect(snapshot.source?.contains("usage endpoint") == true, snapshot.source ?? "no source")
                let status = await provider.sourceStatus()
                let shown = String(describing: snapshot) + String(describing: status) + status.fallback.message
                expect(!shown.contains(X.token) && !shown.contains(X.refresh), "the sign-in reached what Brim shows")

                settings.refreshWhileClosed = false
                await provider.update(settings: settings, showSessionTitles: false)
                let after = await provider.fetchSnapshot(now: now.addingTimeInterval(3600))
                let off = await provider.sourceStatus()
                expectEqual(off.fallback, .off)
                expectEqual(endpoint.tokens.count, 1)
                expect(after.source?.contains("usage endpoint") != true, "kept using the fetched figure after switching off")
            }
        },
    ])
}
