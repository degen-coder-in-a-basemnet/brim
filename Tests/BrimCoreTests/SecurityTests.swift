import Foundation
@testable import BrimCore

enum SecurityTests {
    static let suite = TestSuite("Security", [
        test("redacts credential shapes") {
            let samples = [
                "key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA",
                "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
                #"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlc2lnbg"}"#,
                "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
                "https://user:hunter2@proxy.example.com:8080",
                "cookie: sessionKey=sk-ant-sid01-xyzxyzxyzxyzxyzxyz",
                "password=correct-horse-battery",
                "0123456789abcdef0123456789abcdef0123456789abcdef",
            ]
            for sample in samples {
                let redacted = Redactor.redact(sample)
                expect(redacted.contains(Redactor.marker), "not redacted: \(sample) -> \(redacted)")
            }
            expect(!Redactor.redact("key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA").contains("AAAAAAAAAAAA"))
            expect(!Redactor.redact("https://user:hunter2@proxy.example.com").contains("hunter2"))
        },
        test("leaves ordinary status text alone") {
            let plain = "Ollama isn't running on 127.0.0.1:11434."
            expectEqual(Redactor.redact(plain), plain)
            expectEqual(Redactor.statusLine(String(repeating: "a b ", count: 100), limit: 20).count, 20)
        },
        test("file access refuses anything outside its roots") {
            try await withTemporaryDirectory { root in
                let allowed = root.appendingPathComponent("allowed")
                let secret = root.appendingPathComponent("secret.txt")
                write("inside", to: allowed.appendingPathComponent("a.txt"))
                write("SECRET", to: secret)
                let access = LocalFileAccess(allowedRoots: [allowed])
                expectEqual(String(decoding: try access.contents(of: allowed.appendingPathComponent("a.txt")), as: UTF8.self), "inside")
                expectThrows { _ = try access.contents(of: secret) }
                expectThrows { _ = try access.contents(of: allowed.appendingPathComponent("../secret.txt")) }
                // A symlink planted inside the root does not reach out of it.
                try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("link.txt"), withDestinationURL: secret)
                expectThrows { _ = try access.contents(of: allowed.appendingPathComponent("link.txt")) }
                expect(!access.isAllowed(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Keychains/login.keychain-db")))
                expect(!access.isAllowed(allowed.appendingPathComponent("../allowed-sibling/x")))
            }
        },
        test("line reads are incremental and bounded") {
            try await withTemporaryDirectory { root in
                let file = root.appendingPathComponent("log.jsonl")
                write("one\ntwo\nthr", to: file)
                let access = LocalFileAccess(allowedRoots: [root])
                let first = try access.lines(of: file, from: 0)
                expectEqual(first.lines.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
                expectEqual(first.next, 8)
                write("one\ntwo\nthree\nfour\n", to: file)
                let second = try access.lines(of: file, from: first.next)
                expectEqual(second.lines.map { String(decoding: $0, as: UTF8.self) }, ["three", "four"])
                expectThrows { _ = try access.contents(of: file, maxBytes: 4) }
                write("x", to: file)
                expectEqual(try access.lines(of: file, from: second.next).next, 0, "a shrunken file restarts")
            }
        },
        test("loopback requests only reach 127.0.0.1 on allowlisted paths") {
            let allowlist = LoopbackHTTPClient.Allowlist(paths: ["/api/ps"])
            let url = try unwrap(LoopbackHTTPClient.url(port: 11434, path: "/api/ps", allowlist: allowlist))
            expectEqual(url.absoluteString, "http://127.0.0.1:11434/api/ps")
            expectNil(LoopbackHTTPClient.url(port: 11434, path: "/api/pull", allowlist: allowlist))
            expectNil(LoopbackHTTPClient.url(port: 0, path: "/api/ps", allowlist: allowlist))
            expectNil(LoopbackHTTPClient.url(port: 70000, path: "/api/ps", allowlist: allowlist))
            expect(!LoopbackHTTPClient.isLoopback(URL(string: "https://api.anthropic.com/")!))
            expect(!LoopbackHTTPClient.isLoopback(URL(string: "http://example.com/")!))
            expect(LoopbackHTTPClient.isLoopback(URL(string: "http://127.0.0.1:1234/api/v0/models")!))
        },
        test("a refused connection is reported, not thrown past the adapter") {
            // Port 9 (discard) is essentially never listening on a Mac.
            let client = LoopbackHTTPClient(timeout: 1)
            do {
                _ = try await client.get(port: 9, path: "/api/ps", allowlist: .init(paths: ["/api/ps"]))
                expect(false, "expected a failure")
            } catch let error as LoopbackHTTPClient.RequestError {
                expect(error == .connectionRefused || error == .unreachable || error == .timedOut, "\(error)")
            }
        },
        test("the process runner uses absolute paths, captures output and enforces its timeout") {
            try await withTemporaryDirectory { root in
                let runner = ProcessRunner(timeout: 1)
                let output = try await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], workingDirectory: root)
                expectEqual(String(decoding: output, as: UTF8.self), "hello\n")
                do {
                    _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], workingDirectory: root)
                    expect(false, "sleep should have timed out")
                } catch let error as ProcessRunner.RunError {
                    expectEqual(error, .timedOut)
                }
                do {
                    _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/claude"), arguments: [], workingDirectory: root)
                    expect(false, "missing binary should fail")
                } catch let error as ProcessRunner.RunError {
                    expectEqual(error, .notExecutable)
                }
            }
        },
        test("the child environment carries nothing sensitive") {
            try await withTemporaryDirectory { root in
                setenv("BRIM_TEST_SECRET", "sk-ant-should-not-pass", 1)
                defer { unsetenv("BRIM_TEST_SECRET") }
                let output = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/env"), arguments: [], workingDirectory: root)
                let env = String(decoding: output, as: UTF8.self)
                expect(!env.contains("BRIM_TEST_SECRET"))
                expect(env.contains("PATH="))
            }
        },
    ])
}

enum PersistenceTests {
    static let suite = TestSuite("Persistence", [
        test("missing or broken fields fall back to defaults") {
            let json = #"{"edge":"left","size":"enormous","refreshInterval":300,"claude":{"useUsageCommand":true}}"#
            let settings = try JSONDecoder.brim.decode(AppSettings.self, from: Data(json.utf8))
            expectEqual(settings.edge, .left)
            expectEqual(settings.size, .medium)
            expectEqual(settings.refreshInterval, 300)
            expect(settings.claude.useUsageCommand)
            expect(settings.claude.calibrateFromLimitHits)
            expectEqual(settings.visibility, .onHover)
        },
        test("settings round-trip") {
            var settings = AppSettings()
            settings.edge = .top
            settings.setAlongOffset(-120, for: .top)
            settings.manualProviders = [ManualProviderConfig(name: "Cursor", windows: [
                ManualWindow(label: "Requests", limit: 500, used: 3, schedule: .weekly(weekday: 2, hour: 9, minute: 0),
                             lastReset: date("2026-09-20T00:00:00Z")),
            ])]
            let data = try JSONEncoder.brim.encode(settings)
            let back = try JSONDecoder.brim.decode(AppSettings.self, from: data)
            expectEqual(back, settings)
            expectEqual(back.alongOffset(for: .top), -120)
            expectEqual(back.alongOffset(for: .right), 0)
        },
        test("nothing credential-like is ever part of the settings") {
            let text = String(decoding: try JSONEncoder.brim.encode(AppSettings()), as: UTF8.self).lowercased()
            for word in ["token\"", "apikey", "api_key", "password", "cookie", "secret", "bearer", "keychain"] {
                expect(!text.contains(word), "settings mention \(word)")
            }
        },
        test("networked providers start switched off") {
            let settings = AppSettings()
            expect(settings.isEnabled("claudeCode", kind: .claudeCode))
            expect(settings.isEnabled("codex", kind: .codex))
            expect(!settings.isEnabled("ollama", kind: .ollama))
            expect(!settings.isEnabled("lmStudio", kind: .lmStudio))
            expect(!settings.claude.useUsageCommand)
            for kind in ProviderKind.allCases where kind.network.isNetworked {
                expect(!kind.enabledByDefault, "\(kind) is networked and on by default")
            }
        },
        test("settings files are private to the user") { @MainActor in
            await withTemporaryDirectory { root in
                let store = SettingsStore(directory: root)
                store.update { $0.edge = .bottom }
                store.saveNow()
                let attributes = try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)
                expectEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                expectEqual(SettingsStore(directory: root).settings.edge, .bottom)
            }
        },
        test("the archive keeps aggregates and shows them stale") { @MainActor in
            try await withTemporaryDirectory { root in
                let archive = ReadingArchiveStore(directory: root)
                let captured = date("2026-09-24T10:00:00Z")
                let snapshot = ProviderSnapshot(id: "codex", kind: .codex, displayName: "Codex", glyph: .prompt,
                                                fidelity: .official,
                                                windows: [LimitWindow(id: "primary", label: "5-hour limit", usedFraction: 0.4)],
                                                capturedAt: captured, source: "x")
                archive.remember(snapshot)
                archive.remember(DemoData.snapshot(id: "demo.claude", now: captured))
                archive.saveNow()
                let reloaded = ReadingArchiveStore(directory: root).archive
                expectEqual(Array(reloaded.readings.keys), ["codex"], "demo data is never archived")
                let restored = try unwrap(reloaded.readings["codex"]).staleSnapshot
                expectEqual(restored.status, .stale(since: captured))
                expectApprox(restored.usedFraction, 0.4)
            }
        },
    ])
}

enum StoreTests {
    static let suite = TestSuite("Usage store", [
        test("demo mode shows the four demo providers in order") { @MainActor in
            var settings = AppSettings()
            settings.demoMode = true
            let store = UsageStore(settingsStore: SettingsStore(settings: settings), archive: ReadingArchiveStore(inMemory: .init()),
                                   fixedNow: date("2026-09-24T12:00:30Z"))
            await store.loadOnce()
            expectEqual(store.snapshots.map(\.id), DemoData.ids)
            expectEqual(store.snapshots.first?.headlineText, "73%")
            expect(!store.activity.isEmpty)
        },
        test("the saved order is applied") { @MainActor in
            var settings = AppSettings()
            settings.demoMode = true
            settings.providerOrder = ["demo.ollama", "demo.codex"]
            let store = UsageStore(settingsStore: SettingsStore(settings: settings), archive: ReadingArchiveStore(inMemory: .init()))
            await store.loadOnce()
            expectEqual(store.snapshots.map(\.id), ["demo.ollama", "demo.codex", "demo.claude", "demo.cursor"])
        },
        test("switching a provider off removes it and forgets its reading") { @MainActor in
            var settings = AppSettings()
            settings.demoMode = true
            let settingsStore = SettingsStore(settings: settings)
            let store = UsageStore(settingsStore: settingsStore, archive: ReadingArchiveStore(inMemory: .init()))
            await store.loadOnce()
            store.start()
            store.setEnabled(false, id: "demo.codex")
            expect(!store.snapshots.contains { $0.id == "demo.codex" })
            store.stop()
        },
        test("a real home with nothing installed yields statuses, not numbers") { @MainActor in
            await withTemporaryDirectory { home in
                var settings = AppSettings()
                settings.enabledProviders = ["ollama": true]
                settings.ollama.port = 9
                let environment = ProviderEnvironment(home: home, applicationSupport: home.appendingPathComponent("support"))
                let store = UsageStore(settingsStore: SettingsStore(settings: settings),
                                       archive: ReadingArchiveStore(inMemory: .init()), environment: environment)
                await store.loadOnce()
                let byID = Dictionary(uniqueKeysWithValues: store.snapshots.map { ($0.id, $0) })
                expect(byID["claudeCode"]?.status.isProblem == true)
                expect(byID["codex"]?.status.isProblem == true)
                expect(byID["ollama"]?.status.isProblem == true)
                expect(store.snapshots.allSatisfy { !$0.hasReading }, "no provider may invent a percentage")
            }
        },
    ])
}
