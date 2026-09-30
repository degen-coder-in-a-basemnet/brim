import Foundation

/// A deliberately small test harness: named cases grouped in suites, a few
/// assertions, and a runner that prints one line per failure and exits non-zero
/// when anything failed. It exists because the toolchain on the development Mac
/// cannot run XCTest or Swift Testing (see scripts/test.sh).

struct TestCase {
    let name: String
    let body: () async throws -> Void
}

struct TestSuite {
    let name: String
    let cases: [TestCase]

    init(_ name: String, _ cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}

func test(_ name: String, _ body: @escaping () async throws -> Void) -> TestCase {
    TestCase(name: name, body: body)
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Failures recorded by the case currently running.
nonisolated(unsafe) var currentFailures: [String] = []

private func record(_ message: String, _ file: StaticString, _ line: UInt) {
    let name = ("\(file)" as NSString).lastPathComponent
    currentFailures.append("\(name):\(line): \(message)")
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !condition() { record(message(), file, line) }
    } catch {
        record("threw \(error)", file, line)
    }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try actual(), e = try expected()
        if a != e { record("expected \(e), got \(a)\(message.isEmpty ? "" : " — \(message)")", file, line) }
    } catch {
        record("threw \(error)", file, line)
    }
}

func expectApprox(_ actual: Double?, _ expected: Double, tolerance: Double = 1e-9,
                  file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return record("expected ≈\(expected), got nil", file, line) }
    if abs(actual - expected) > tolerance { record("expected ≈\(expected), got \(actual)", file, line) }
}

func expectNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try value() { record("expected nil, got \(value) \(message)", file, line) }
    } catch {
        record("threw \(error)", file, line)
    }
}

func expectNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "value was nil",
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try value() == nil { record(message, file, line) }
    } catch {
        record("threw \(error)", file, line)
    }
}

func expectThrows(_ body: () throws -> Void, _ message: String = "expected an error",
                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        try body()
        record(message, file, line)
    } catch {}
}

func unwrap<T>(_ value: T?, _ message: String = "unexpected nil",
               file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else {
        record(message, file, line)
        throw TestFailure(description: message)
    }
    return value
}

/// A temporary directory removed when the case ends.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("brim-tests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.data(using: .utf8)!.write(to: url)
}

/// A fixed calendar in UTC, so date tests mean the same thing everywhere.
var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else { fatalError("bad test date \(text)") }
    return date
}

enum TestRunner {
    static func run(_ suites: [TestSuite], filters: [String]) async -> Int32 {
        var passed = 0, failed = 0
        let start = Date()
        for suite in suites {
            let cases = suite.cases.filter { testCase in
                filters.isEmpty || filters.contains { suite.name.contains($0) || testCase.name.contains($0) }
            }
            guard !cases.isEmpty else { continue }
            var suiteFailures = 0
            for testCase in cases {
                currentFailures = []
                do {
                    try await testCase.body()
                } catch let error as TestFailure {
                    if currentFailures.isEmpty { currentFailures.append(error.description) }
                } catch {
                    currentFailures.append("threw \(error)")
                }
                if currentFailures.isEmpty {
                    passed += 1
                } else {
                    failed += 1
                    suiteFailures += 1
                    print("✗ \(suite.name) › \(testCase.name)")
                    for failure in currentFailures { print("    \(failure)") }
                }
            }
            print("\(suiteFailures == 0 ? "✓" : "✗") \(suite.name) (\(cases.count) cases)")
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
        print("\n\(passed + failed) tests, \(passed) passed, \(failed) failed in \(elapsed)s")
        return failed == 0 ? 0 : 1
    }
}
