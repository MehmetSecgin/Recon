import Foundation

enum KubectlConfigOutputParsing {
    struct TargetFields: Equatable {
        let context: String?
        let namespace: String?
    }

    static func parseTargetFields(from output: String) -> TargetFields {
        let line = firstNonEmptyLine(in: output)
        guard let line else {
            return TargetFields(context: nil, namespace: nil)
        }

        let fields = line
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

        return TargetFields(
            context: fields.first ?? nil,
            namespace: fields.count > 1 ? fields[1] : nil
        )
    }

    private static func firstNonEmptyLine(in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }
}
