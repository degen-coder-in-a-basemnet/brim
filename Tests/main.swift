import Foundation

let suites: [TestSuite] = [
    ModelTests.suite,
    CopyTests.suite,
    AlertTests.suite,
    TransitionTests.suite,
    AttentionTests.suite,
    FocusTests.suite,
    OrderingTests.suite,
    StalenessTests.suite,
    ClaudeParsingTests.suite,
    ClaudeEstimatorTests.suite,
    ClaudeScannerTests.suite,
    ClaudeSessionTests.suite,
    ClaudeCLITests.suite,
    ClaudeOfficialTests.suite,
    ClaudeHandoffTests.suite,
    ClaudeFallbackTests.suite,
    CodexTests.suite,
    LocalRuntimeTests.suite,
    ManualTests.suite,
    DemoTests.suite,
    SecurityTests.suite,
    PersistenceTests.suite,
    StoreTests.suite,
] + uiSuites

let code = await TestRunner.run(suites, filters: Array(CommandLine.arguments.dropFirst()))
exit(code)
