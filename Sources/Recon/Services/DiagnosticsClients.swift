import Foundation

struct DiagnosticsControllerClient {
    let fetchDiagnosticsHealthSnapshot: @MainActor @Sendable () async -> DiagnosticsHealthSnapshot
    let exportDiagnosticBundle: @MainActor @Sendable () async -> DiagnosticExportOutcome
    let copyStatusCommand: @MainActor @Sendable () -> Void

    static func live(_ controller: TelepresenceController) -> Self {
        Self(
            fetchDiagnosticsHealthSnapshot: {
                await controller.fetchDiagnosticsHealthSnapshot()
            },
            exportDiagnosticBundle: {
                await controller.exportDiagnosticBundle()
            },
            copyStatusCommand: {
                controller.copyStatusCommand()
            }
        )
    }
}

struct DiagnosticsHistoryStoreClient: Sendable {
    let prepare: @Sendable () async throws -> Void
    let insert: @Sendable (DiagnosticsEvent) async throws -> Void
    let recentHistory: @Sendable (Int) async throws -> [DiagnosticsHistoryItem]

    static func live(_ store: EventHistoryStore) -> Self {
        Self(
            prepare: {
                try await store.prepare()
            },
            insert: { event in
                try await store.insert(event)
            },
            recentHistory: { limit in
                try await store.recentHistory(limit: limit)
            }
        )
    }
}

struct DiagnosticsCommandHistoryStoreClient: Sendable {
    let prepare: @Sendable () async throws -> Void
    let recentSummaries: @Sendable (Int) async throws -> [CommandHistorySummaryItem]
    let detail: @Sendable (Int64) async throws -> CommandHistoryDetailItem?

    static func live(_ store: CommandHistoryStore) -> Self {
        Self(
            prepare: {
                try await store.prepare()
            },
            recentSummaries: { limit in
                try await store.recentSummaries(limit: limit)
            },
            detail: { id in
                try await store.detail(id: id)
            }
        )
    }
}

struct DiagnosticsLogServiceClient: Sendable {
    let snapshot: @Sendable (DiagnosticsLogSource?) async -> DiagnosticsLogSnapshot
    let poll: @Sendable (DiagnosticsLogSource?) async -> DiagnosticsLogSnapshot
    let openInConsole: @Sendable (DiagnosticsLogSource?) async -> Void
    let reveal: @Sendable (DiagnosticsLogSource?) async -> Void
    let backfillEvents: @Sendable () async -> DiagnosticsBackfillResult
    let reset: @Sendable () async -> Void

    static func live(_ service: DiagnosticsLogService) -> Self {
        Self(
            snapshot: { source in
                await service.snapshot(for: source)
            },
            poll: { source in
                await service.poll(for: source)
            },
            openInConsole: { source in
                await service.openInConsole(source: source)
            },
            reveal: { source in
                await service.reveal(source: source)
            },
            backfillEvents: {
                await service.backfillEvents()
            },
            reset: {
                await service.reset()
            }
        )
    }
}
