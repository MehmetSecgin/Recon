import Foundation

@main
struct CommandHistoryHarness {
    static func main() async throws {
        try await testStoreInsertAndRead()
        try await testTwentyFourHourPruning()
        try await testThrottledPruneOnInsert()
        try await testEmptyStreamsPersistAsEmptyStrings()
        try await testProcessRunnerSuccessLogging()
        try await testProcessRunnerNonZeroExitLogging()
        try await testProcessRunnerTimeoutLogging()
        try await testProcessRunnerLaunchFailureLogging()
        try await testAppInstallerRelaunchIsExcluded()
        try await testConfigViewOutputIsSummarized()
        try await testCompactConfigViewOutputIsSummarized()
        try await testConfigMapsPayloadIsRedacted()
        try await testGenericSensitiveKeyRedaction()
        try await testEnvShapedJSONRedaction()
        try await testOutputTruncationFlags()
        try await testHugeJSONOutputGetsSummarizedBeforeParsing()
        try await testCommandsTabLoadsOnlyWhenActive()
        try await testStatusPollFilteringDefaultsToHidden()
        try await testRowExpansionLoadsDetailLazily()
        try await testCommandsStateClearsOnTabSwitchAndWindowClose()

        print("Command history harness passed")
    }

    private static func testStoreInsertAndRead() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 10_000))
        try await store.prepare()

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 9_900),
                finishedAt: Date(timeIntervalSince1970: 9_901),
                executable: "/usr/bin/env",
                arguments: ["foo", "bar"],
                source: .environmentProbe,
                context: "ctx-a",
                namespace: "ns-a",
                resultState: .success,
                exitCode: 0,
                stdout: "hello",
                stderr: "warn"
            )
        )

        let summaries = try await store.recentSummaries(limit: 10)
        try expect(summaries.count == 1, "Expected one command summary row")
        let summary = try require(summaries.first, "Expected a command summary item")
        try expect(summary.arguments == ["foo", "bar"], "Arguments should round-trip from SQLite")
        try expect(summary.source == .environmentProbe, "Source should persist")
        try expect(summary.context == "ctx-a", "Context should persist")
        try expect(summary.namespace == "ns-a", "Namespace should persist")

        let detail = try require(try await store.detail(id: summary.id), "Expected command detail row")
        try expect(detail.stdout == "hello", "stdout should persist")
        try expect(detail.stderr == "warn", "stderr should persist")
    }

    private static func testTwentyFourHourPruning() async throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let store = makeStore(now: now)
        try await store.prepare()

        try await store.insert(
            makeRecord(
                startedAt: now.addingTimeInterval(-(25 * 60 * 60)),
                finishedAt: now.addingTimeInterval(-(25 * 60 * 60) + 1),
                executable: "/bin/echo",
                arguments: ["old"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: "old",
                stderr: ""
            )
        )

        try await store.insert(
            makeRecord(
                startedAt: now.addingTimeInterval(-60),
                finishedAt: now.addingTimeInterval(-59),
                executable: "/bin/echo",
                arguments: ["new"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: "new",
                stderr: ""
            )
        )

        _ = try await store.recentSummaries(limit: 10)
        let expiredDetail = try await store.detail(id: 1)
        let freshDetail = try await store.detail(id: 2)
        try expect(expiredDetail == nil, "Prepare/list pruning should remove rows older than 24 hours")
        try expect(freshDetail != nil, "Recent rows should remain after pruning")
    }

    private static func testThrottledPruneOnInsert() async throws {
        let now = Date(timeIntervalSince1970: 300_000)
        let store = makeStore(now: now)

        try await store.insert(
            makeRecord(
                startedAt: now.addingTimeInterval(-(26 * 60 * 60)),
                finishedAt: now.addingTimeInterval(-(26 * 60 * 60) + 1),
                executable: "/bin/echo",
                arguments: ["old"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: "old",
                stderr: ""
            )
        )

        for index in 0..<48 {
            try await store.insert(
                makeRecord(
                    startedAt: now.addingTimeInterval(TimeInterval(index)),
                    finishedAt: now.addingTimeInterval(TimeInterval(index) + 0.1),
                    executable: "/bin/echo",
                    arguments: ["keep-\(index)"],
                    source: .other,
                    resultState: .success,
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            )
        }

        let preservedBeforeThreshold = try await store.detail(id: 1)
        try expect(preservedBeforeThreshold != nil, "Pruning should stay throttled before the threshold is reached")

        try await store.insert(
            makeRecord(
                startedAt: now.addingTimeInterval(100),
                finishedAt: now.addingTimeInterval(101),
                executable: "/bin/echo",
                arguments: ["trigger"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )

        let prunedAfterThreshold = try await store.detail(id: 1)
        try expect(prunedAfterThreshold == nil, "The 50th insert should trigger retention pruning")
    }

    private static func testEmptyStreamsPersistAsEmptyStrings() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 400_000))
        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 399_000),
                finishedAt: Date(timeIntervalSince1970: 399_001),
                executable: "/bin/echo",
                arguments: [],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: "",
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected command detail row")
        try expect(detail.stdout == "", "Missing stdout should persist as an empty string")
        try expect(detail.stderr == "", "Missing stderr should persist as an empty string")
    }

    private static func testProcessRunnerSuccessLogging() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 500_000))
        try await withSharedStore(store) {
            let output = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'ok'"],
                metadata: ProcessRunMetadata(source: .clusterBrowser, context: "ctx", namespace: "ns")
            )

            try expect(output.exitCode == 0, "Success command should exit 0")
            let detail = try require(try await store.detail(id: 1), "Expected success log row")
            try expect(detail.resultState == .success, "Successful command should log success")
            try expect(detail.stdout == "ok", "stdout should be captured")
            try expect(detail.source == .clusterBrowser, "Metadata source should persist")
            try expect(detail.context == "ctx", "Metadata context should persist")
            try expect(detail.namespace == "ns", "Metadata namespace should persist")
        }
    }

    private static func testProcessRunnerNonZeroExitLogging() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 600_000))
        try await withSharedStore(store) {
            let output = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'boom' >&2; exit 7"],
                metadata: ProcessRunMetadata(source: .telepresenceAction)
            )

            try expect(output.exitCode == 7, "Non-zero command should return its exit code")
            let detail = try require(try await store.detail(id: 1), "Expected non-zero log row")
            try expect(detail.resultState == .nonZeroExit, "Non-zero exit should log distinctly")
            try expect(detail.exitCode == 7, "Exit code should persist")
            try expect(detail.stderr.contains("boom"), "stderr should be captured for non-zero exits")
        }
    }

    private static func testProcessRunnerTimeoutLogging() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 700_000))
        try await withSharedStore(store) {
            do {
                _ = try await ProcessRunner.run(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'wait'; sleep 2"],
                    timeout: .seconds(1),
                    metadata: ProcessRunMetadata(source: .statusPoll)
                )
                throw Failure("Expected timeout to throw")
            } catch is ProcessRunner.TimeoutError {
                let detail = try require(try await store.detail(id: 1), "Expected timeout log row")
                try expect(detail.resultState == .timeout, "Timeouts should log with timeout state")
                try expect(detail.source == .statusPoll, "Timeout log should preserve metadata source")
            }
        }
    }

    private static func testProcessRunnerLaunchFailureLogging() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 800_000))
        try await withSharedStore(store) {
            do {
                _ = try await ProcessRunner.run(
                    executable: "/definitely/missing/executable",
                    arguments: [],
                    metadata: ProcessRunMetadata(source: .appInstall)
                )
                throw Failure("Expected launch failure to throw")
            } catch {
                let detail = try require(try await store.detail(id: 1), "Expected launch-failure log row")
                try expect(detail.resultState == .launchFailure, "Launch failures should be logged")
                try expect(detail.source == .appInstall, "Launch-failure metadata should persist")
            }
        }
    }

    private static func testAppInstallerRelaunchIsExcluded() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 900_000))
        let installer = AppInstaller(
            processLauncher: { _ in },
            appOpener: { _ in }
        )

        try await withSharedStore(store) {
            installer.relaunchInstalledAppAfterCurrentProcessExits()
            let summaries = try await store.recentSummaries(limit: 10)
            try expect(summaries.isEmpty, "Relaunch helper should remain intentionally unlogged")
        }
    }

    private static func testConfigViewOutputIsSummarized() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_000_000))
        let rawOutput = """
        {
          "current-context": "dev-cluster",
          "clusters": [{"name": "dev", "cluster": {"certificate-authority-data": "SECRET-CA"}}],
          "contexts": [{"name": "dev-cluster"}],
          "users": [{"name": "dev-user", "user": {"token": "VERY-SECRET"}}]
        }
        """

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 999_000),
                finishedAt: Date(timeIntervalSince1970: 999_001),
                executable: "/usr/bin/kubectl",
                arguments: ["config", "view", "-o", "json"],
                source: .kubeTargetResolution,
                resultState: .success,
                exitCode: 0,
                stdout: rawOutput,
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected config-view row")
        try expect(detail.stdout.contains("[redacted kubectl config view output]"), "config view output should be summarized")
        try expect(detail.stdout.contains("current-context: dev-cluster"), "config view summary should preserve the safe current context")
        try expect(detail.stdout.contains("VERY-SECRET") == false, "config view output should not retain raw secrets")
    }

    private static func testCompactConfigViewOutputIsSummarized() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_050_000))

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_049_000),
                finishedAt: Date(timeIntervalSince1970: 1_049_001),
                executable: "/usr/bin/kubectl",
                arguments: ["config", "view", "--minify", "-o", #"jsonpath={.current-context}{"\t"}{.contexts[0].context.namespace}"#],
                source: .kubeTargetResolution,
                resultState: .success,
                exitCode: 0,
                stdout: "prod-eu1\tpayments\n",
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected compact config-view row")
        try expect(detail.stdout.contains("[redacted kubectl config view output]"), "Compact config view output should still be summarized")
        try expect(detail.stdout.contains("current-context: prod-eu1"), "Compact config view summary should preserve the current context")
        try expect(detail.stdout.contains("current-namespace: payments"), "Compact config view summary should preserve the namespace")
    }

    private static func testConfigMapsPayloadIsRedacted() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_100_000))
        let rawOutput = """
        {
          "items": [
            {
              "metadata": {"name": "example"},
              "data": {"token": "abc", "normal": "value"},
              "binaryData": {"blob": "c2VjcmV0"},
              "stringData": {"password": "def"}
            }
          ]
        }
        """

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_099_000),
                finishedAt: Date(timeIntervalSince1970: 1_099_001),
                executable: "/usr/bin/kubectl",
                arguments: ["get", "configmaps", "-o", "json"],
                source: .clusterBrowser,
                resultState: .success,
                exitCode: 0,
                stdout: rawOutput,
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected configmaps row")
        try expect(detail.stdout.contains("<redacted"), "ConfigMap payload bodies should be replaced with placeholders")
        try expect(detail.stdout.contains("\"token\"") == false, "ConfigMap data values should not survive redaction")
        try expect(detail.stdout.contains("c2VjcmV0") == false, "binaryData values should be redacted")
    }

    private static func testGenericSensitiveKeyRedaction() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_200_000))
        let stdout = """
        {"token":"abc","nested":{"password":"def","secret":"ghi"}}
        """
        let stderr = """
        API_TOKEN=raw-token
        PASSWORD: raw-password
        """

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_199_000),
                finishedAt: Date(timeIntervalSince1970: 1_199_001),
                executable: "/bin/echo",
                arguments: ["plain"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: stdout,
                stderr: stderr
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected generic redaction row")
        try expect(detail.stdout.contains("abc") == false, "JSON sensitive values should be redacted")
        try expect(detail.stderr.contains("raw-token") == false, "Plain-text token values should be redacted")
        try expect(detail.stderr.contains("raw-password") == false, "Plain-text password values should be redacted")
    }

    private static func testEnvShapedJSONRedaction() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_300_000))
        let rawOutput = """
        {
          "spec": {
            "containers": [
              {
                "env": [
                  {"name": "API_TOKEN", "value": "top-secret"},
                  {"name": "SAFE_NAME", "value": "keep-me"}
                ]
              }
            ]
          }
        }
        """

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_299_000),
                finishedAt: Date(timeIntervalSince1970: 1_299_001),
                executable: "/bin/echo",
                arguments: ["json"],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: rawOutput,
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected env redaction row")
        try expect(detail.stdout.contains("top-secret") == false, "Sensitive env-shaped values should be redacted")
        try expect(detail.stdout.contains("keep-me"), "Non-sensitive env values should remain")
    }

    private static func testOutputTruncationFlags() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_400_000))
        let giantOutput = String(repeating: "x", count: 150 * 1024)

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_399_000),
                finishedAt: Date(timeIntervalSince1970: 1_399_001),
                executable: "/bin/echo",
                arguments: [],
                source: .other,
                resultState: .success,
                exitCode: 0,
                stdout: giantOutput,
                stderr: giantOutput
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected truncation test row")
        try expect(detail.stdoutTruncated, "stdout truncation flag should be set")
        try expect(detail.stderrTruncated, "stderr truncation flag should be set")
        try expect(detail.stdout.lengthOfBytes(using: .utf8) <= 128 * 1024, "stdout should be capped after redaction")
        try expect(detail.stderr.lengthOfBytes(using: .utf8) <= 128 * 1024, "stderr should be capped after redaction")
    }

    private static func testHugeJSONOutputGetsSummarizedBeforeParsing() async throws {
        let store = makeStore(now: Date(timeIntervalSince1970: 1_450_000))
        let repeatedItem = #"{"metadata":{"name":"pod"},"spec":{"token":"secret-value"}}"#
        let hugeJSON = "{\n\"items\":[\n" + Array(repeating: repeatedItem, count: 20_000).joined(separator: ",\n") + "\n]\n}"

        try await store.insert(
            makeRecord(
                startedAt: Date(timeIntervalSince1970: 1_449_000),
                finishedAt: Date(timeIntervalSince1970: 1_449_001),
                executable: "/usr/bin/kubectl",
                arguments: ["get", "pods", "-o", "json"],
                source: .clusterBrowser,
                resultState: .success,
                exitCode: 0,
                stdout: hugeJSON,
                stderr: ""
            )
        )

        let detail = try require(try await store.detail(id: 1), "Expected huge JSON row")
        try expect(detail.stdout.contains("[output summarized due to size]"), "Huge JSON output should be summarized before expensive redaction")
        try expect(detail.stdout.contains("secret-value") == false, "Summaries should not retain raw JSON secrets")
        try expect(detail.stdoutTruncated, "Huge JSON summary should still mark truncation")
    }

    @MainActor
    private static func testCommandsTabLoadsOnlyWhenActive() async throws {
        let commandStore = FakeCommandStore(
            summaries: [makeSummary(id: 1, source: .statusCheck)],
            details: [1: makeDetail(id: 1, source: .statusCheck)]
        )
        let viewModel = makeDiagnosticsViewModel(commandStore: commandStore)

        viewModel.activateWindow()
        await settle()
        let initialRecentCount = await commandStore.recentCallCount()
        try expect(initialRecentCount == 0, "Commands should not load while another tab is active")

        viewModel.selectTab(.commands)
        await settle()
        let commandsRecentCount = await commandStore.recentCallCount()
        try expect(commandsRecentCount > initialRecentCount, "Commands should load when the Commands tab becomes active")
    }

    @MainActor
    private static func testStatusPollFilteringDefaultsToHidden() async throws {
        let summaries = [
            makeSummary(id: 1, source: .statusPoll),
            makeSummary(id: 2, source: .diagnostics)
        ]
        let commandStore = FakeCommandStore(
            summaries: summaries,
            details: Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, makeDetail(id: $0.id, source: $0.source)) })
        )
        let viewModel = makeDiagnosticsViewModel(commandStore: commandStore)

        viewModel.activateWindow()
        viewModel.selectTab(.commands)
        await settle()

        let loadedCount = viewModel.commandItems.count
        let visibleIDs = viewModel.visibleCommandItems.map(\.id)
        try expect(loadedCount == 2, "All rows should still be loaded into memory")
        try expect(visibleIDs == [2], "Status-poll rows should be hidden by default")
    }

    @MainActor
    private static func testRowExpansionLoadsDetailLazily() async throws {
        let summary = makeSummary(id: 7, source: .clusterBrowser)
        let commandStore = FakeCommandStore(
            summaries: [summary],
            details: [7: makeDetail(id: 7, source: .clusterBrowser)]
        )
        let viewModel = makeDiagnosticsViewModel(commandStore: commandStore)

        viewModel.activateWindow()
        viewModel.selectTab(.commands)
        await settle()

        let initialDetailRequests = await commandStore.detailRequests()
        try expect(initialDetailRequests == [], "Detail rows should not load eagerly")

        viewModel.toggleCommandExpansion(summary)
        await settle()

        let detailRequests = await commandStore.detailRequests()
        let loadedDetailID = viewModel.commandDetail(for: 7)?.id
        try expect(detailRequests == [7], "Expanding a row should load its detail on demand")
        try expect(loadedDetailID == 7, "Expanded row should cache its detail")
    }

    @MainActor
    private static func testCommandsStateClearsOnTabSwitchAndWindowClose() async throws {
        let summary = makeSummary(id: 11, source: .diagnostics)
        let commandStore = FakeCommandStore(
            summaries: [summary],
            details: [11: makeDetail(id: 11, source: .diagnostics)]
        )
        let viewModel = makeDiagnosticsViewModel(commandStore: commandStore)

        viewModel.activateWindow()
        viewModel.selectTab(.commands)
        await settle()
        viewModel.toggleCommandExpansion(summary)
        await settle()

        let hasCommandsAfterLoad = viewModel.commandItems.isEmpty == false
        let hasDetailAfterExpansion = viewModel.commandDetail(for: 11) != nil
        try expect(hasCommandsAfterLoad, "Commands should be present after loading")
        try expect(hasDetailAfterExpansion, "Detail should be loaded after expansion")

        viewModel.selectTab(.health)
        await settle()

        let commandsClearedOnTabSwitch = viewModel.commandItems.isEmpty
        let detailsClearedOnTabSwitch = viewModel.commandDetail(for: 11) == nil
        try expect(commandsClearedOnTabSwitch, "Command list state should clear when leaving the Commands tab")
        try expect(detailsClearedOnTabSwitch, "Command detail state should clear when leaving the Commands tab")

        viewModel.selectTab(.commands)
        await settle()
        let reloadedCommands = viewModel.commandItems.isEmpty == false
        try expect(reloadedCommands, "Command list should load again when returning to Commands")

        viewModel.deactivateWindow()
        await settle()

        let commandsClearedOnClose = viewModel.commandItems.isEmpty
        let detailsClearedOnClose = viewModel.commandDetailItems.isEmpty
        try expect(commandsClearedOnClose, "Command list state should clear when the Diagnostics window closes")
        try expect(detailsClearedOnClose, "Command detail cache should clear when the Diagnostics window closes")
    }

    private static func makeStore(now: Date) -> CommandHistoryStore {
        let clock = MutableClock(now: now)
        return CommandHistoryStore(
            databaseURL: temporaryDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite3"),
            nowProvider: { clock.now }
        )
    }

    private static func makeRecord(
        startedAt: Date,
        finishedAt: Date,
        executable: String,
        arguments: [String],
        source: CommandHistorySource,
        context: String? = nil,
        namespace: String? = nil,
        resultState: CommandHistoryResultState,
        exitCode: Int32?,
        stdout: String,
        stderr: String
    ) -> CommandHistoryEntryRecord {
        CommandHistoryEntryRecord(
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationMs: max(Int64((finishedAt.timeIntervalSince(startedAt) * 1000).rounded()), 0),
            executable: executable,
            arguments: arguments,
            source: source,
            context: context,
            namespace: namespace,
            resultState: resultState,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func makeSummary(id: Int64, source: CommandHistorySource) -> CommandHistorySummaryItem {
        CommandHistorySummaryItem(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_500_000 + TimeInterval(id)),
            finishedAt: Date(timeIntervalSince1970: 1_500_001 + TimeInterval(id)),
            durationMs: 250,
            executable: "/usr/bin/env",
            arguments: ["sample", "\(id)"],
            source: source,
            context: "ctx-\(id)",
            namespace: "ns-\(id)",
            resultState: .success,
            exitCode: 0,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    private static func makeDetail(id: Int64, source: CommandHistorySource) -> CommandHistoryDetailItem {
        CommandHistoryDetailItem(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_500_000 + TimeInterval(id)),
            finishedAt: Date(timeIntervalSince1970: 1_500_001 + TimeInterval(id)),
            durationMs: 250,
            executable: "/usr/bin/env",
            arguments: ["sample", "\(id)"],
            source: source,
            context: "ctx-\(id)",
            namespace: "ns-\(id)",
            resultState: .success,
            exitCode: 0,
            stdout: "detail-\(id)",
            stderr: "",
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    @MainActor
    private static func makeDiagnosticsViewModel(commandStore: FakeCommandStore) -> DiagnosticsViewModel {
        DiagnosticsViewModel(
            controller: DiagnosticsControllerClient(
                fetchDiagnosticsHealthSnapshot: {
                    DiagnosticsHealthSnapshot(
                        status: nil,
                        telepresenceUnavailable: false,
                        unavailableReason: nil,
                        connectedSince: nil
                    )
                },
                exportDiagnosticBundle: {
                    DiagnosticExportOutcome(success: true, summary: "", details: nil, bundleURL: nil)
                },
                copyStatusCommand: {}
            ),
            historyStore: DiagnosticsHistoryStoreClient(
                prepare: {},
                insert: { _ in },
                recentHistory: { _ in [] }
            ),
            commandHistoryStore: DiagnosticsCommandHistoryStoreClient(
                prepare: {
                    await commandStore.prepare()
                },
                recentSummaries: { _ in
                    await commandStore.recentSummaries()
                },
                detail: { id in
                    await commandStore.detail(id: id)
                }
            ),
            logService: DiagnosticsLogServiceClient(
                snapshot: { _ in
                    DiagnosticsLogSnapshot(
                        sourceStates: [],
                        selectedSourceState: nil,
                        entries: [],
                        logsDirectoryExists: false,
                        replacesEntries: true
                    )
                },
                poll: { _ in
                    DiagnosticsLogSnapshot(
                        sourceStates: [],
                        selectedSourceState: nil,
                        entries: [],
                        logsDirectoryExists: false,
                        replacesEntries: false
                    )
                },
                openInConsole: { _ in },
                reveal: { _ in },
                backfillEvents: {
                    DiagnosticsBackfillResult(events: [])
                },
                reset: {}
            )
        )
    }

    private static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recon-command-history-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private static func withSharedStore(
        _ store: CommandHistoryStore,
        operation: () async throws -> Void
    ) async throws {
        let previous = CommandHistoryStore.shared
        CommandHistoryStore.shared = store
        defer { CommandHistoryStore.shared = previous }
        try await operation()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw Failure(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw Failure(message)
        }
        return value
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor FakeCommandStore {
    private let summariesStorage: [CommandHistorySummaryItem]
    private let detailStorage: [Int64: CommandHistoryDetailItem]
    private var prepareCount = 0
    private var recentCount = 0
    private var requestedDetails: [Int64] = []

    init(
        summaries: [CommandHistorySummaryItem],
        details: [Int64: CommandHistoryDetailItem]
    ) {
        summariesStorage = summaries
        detailStorage = details
    }

    func prepare() {
        prepareCount += 1
    }

    func recentSummaries() -> [CommandHistorySummaryItem] {
        recentCount += 1
        return summariesStorage
    }

    func detail(id: Int64) -> CommandHistoryDetailItem? {
        requestedDetails.append(id)
        return detailStorage[id]
    }

    func recentCallCount() -> Int {
        recentCount
    }

    func detailRequests() -> [Int64] {
        requestedDetails
    }
}

private struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
