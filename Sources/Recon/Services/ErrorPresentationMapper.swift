import Foundation

enum ErrorPresentationMapper {
    static func makeStatusPresentation(
        snapshot: TelepresenceStatusSnapshot,
        canOpenLogs: Bool
    ) -> ErrorPresentation? {
        switch snapshot.state {
        case .unavailable:
            return ErrorPresentation(
                title: "Telepresence not found",
                message: "Recon couldn't find the Telepresence CLI.",
                suggestion: "Install Telepresence or set TELEPRESENCE_PATH, then refresh.",
                rawDetailPreview: trimmedPreview(from: snapshot.detailText),
                canCopyStatus: true,
                canOpenLogs: canOpenLogs
            )
        case .error:
            return makeMappedPresentation(
                fallbackTitle: "Status check failed",
                fallbackMessage: "Recon couldn't read Telepresence status.",
                rawSummary: snapshot.statusText,
                rawDetails: snapshot.detailText,
                canOpenLogs: canOpenLogs
            )
        default:
            return nil
        }
    }

    static func makeCommandFailurePresentation(
        outcome: CommandOutcome,
        canOpenLogs: Bool
    ) -> ErrorPresentation {
        makeMappedPresentation(
            fallbackTitle: "Telepresence command failed",
            fallbackMessage: "Recon couldn't complete the requested Telepresence action.",
            rawSummary: outcome.summary,
            rawDetails: outcome.details,
            canOpenLogs: canOpenLogs || !outcome.logPaths.isEmpty
        )
    }

    private static func makeMappedPresentation(
        fallbackTitle: String,
        fallbackMessage: String,
        rawSummary: String,
        rawDetails: String?,
        canOpenLogs: Bool
    ) -> ErrorPresentation {
        let combinedRaw = [rawSummary, rawDetails]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: "\n")

        let normalized = combinedRaw.lowercased()

        if normalized.contains("telepresence executable was not found") ||
            normalized.contains("telepresence not found") {
            return ErrorPresentation(
                title: "Telepresence not found",
                message: "Recon couldn't find the Telepresence CLI.",
                suggestion: "Install Telepresence or set TELEPRESENCE_PATH, then retry.",
                rawDetailPreview: trimmedPreview(from: combinedRaw),
                canCopyStatus: true,
                canOpenLogs: canOpenLogs
            )
        }

        if normalized.contains("failed to launch the daemon service") ||
            normalized.contains("daemon service") && normalized.contains("failed") {
            return ErrorPresentation(
                title: "Telepresence daemon couldn't start",
                message: "The Telepresence daemon failed to launch.",
                suggestion: "Quit any stuck Telepresence processes, then retry or open logs for details.",
                rawDetailPreview: trimmedPreview(from: combinedRaw),
                canCopyStatus: true,
                canOpenLogs: canOpenLogs
            )
        }

        if normalized.contains("kubeconfig has no context definition") ||
            normalized.contains("no context definition") && normalized.contains("kubeconfig") {
            return ErrorPresentation(
                title: "Kubeconfig context is missing",
                message: "The selected kubeconfig doesn't define the expected context.",
                suggestion: "Check the kubeconfig's current context or switch to a different file.",
                rawDetailPreview: trimmedPreview(from: combinedRaw),
                canCopyStatus: true,
                canOpenLogs: canOpenLogs
            )
        }

        if normalized.contains("traffic manager") &&
            (normalized.contains("not found") || normalized.contains("unreachable") || normalized.contains("failed")) {
            return ErrorPresentation(
                title: "Traffic Manager is unavailable",
                message: "Telepresence couldn't reach the cluster-side Traffic Manager.",
                suggestion: "Install or repair the Traffic Manager, then reconnect.",
                rawDetailPreview: trimmedPreview(from: combinedRaw),
                canCopyStatus: true,
                canOpenLogs: canOpenLogs
            )
        }

        return ErrorPresentation(
            title: fallbackTitle,
            message: fallbackMessage,
            suggestion: "Retry the action, copy the status command, or open logs for more detail.",
            rawDetailPreview: trimmedPreview(from: combinedRaw),
            canCopyStatus: true,
            canOpenLogs: canOpenLogs
        )
    }

    private static func trimmedPreview(from rawText: String?) -> String? {
        let lines = rawText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3) ?? []

        let preview = Array(lines).joined(separator: "\n")
        return preview.nilIfEmpty
    }
}
