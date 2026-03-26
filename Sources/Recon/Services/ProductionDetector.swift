import Foundation

enum ProductionDetector {
    private static let defaultsKey = "Recon.ProductionContextPatterns"

    static func isProduction(context: String?) -> Bool {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return false
        }

        let normalizedContext = context.lowercased()
        if normalizedContext.contains("prod") {
            return true
        }

        // Custom patterns are additive and case-insensitive; they do not replace the built-in "prod" match.
        let customPatterns = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return customPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { pattern in
                !pattern.isEmpty && normalizedContext.contains(pattern)
            }
    }
}
