import Foundation

@MainActor
final class DiagnosticsEventRecorder {
    private let controller: TelepresenceController
    private let historyStore: EventHistoryStore
    private var eventSubscriptionTask: Task<Void, Never>?

    init(
        controller: TelepresenceController,
        historyStore: EventHistoryStore = EventHistoryStore()
    ) {
        self.controller = controller
        self.historyStore = historyStore

        eventSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareHistoryStore()
            let stream = self.controller.diagnosticsEventStream()
            for await event in stream {
                await self.persist(event: event)
            }
        }
    }

    deinit {
        eventSubscriptionTask?.cancel()
    }

    private func prepareHistoryStore() async {
        do {
            try await historyStore.prepare()
        } catch {
            // Keep the recorder lightweight and non-fatal if history storage is unavailable.
        }
    }

    private func persist(event: DiagnosticsEvent) async {
        do {
            try await historyStore.insert(event)
        } catch {
            // Ignore persistence failures here; the diagnostics UI can still surface storage errors later.
        }
    }
}
