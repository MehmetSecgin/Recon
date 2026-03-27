import Foundation

enum ProductionDetector {
    private static let defaultsKey = "Recon.ProductionContextPatterns"

    static func isProduction(context: String?) -> Bool {
        isProductionLabel(context)
    }

    static func isProductionNamespace(_ namespace: String?) -> Bool {
        isProductionLabel(namespace)
    }

    private static func isProductionLabel(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }

        let normalizedValue = value.lowercased()
        if normalizedValue.contains("prod") {
            return true
        }

        // Custom patterns are additive and case-insensitive; they do not replace the built-in "prod" match.
        let customPatterns = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return customPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { pattern in
                !pattern.isEmpty && normalizedValue.contains(pattern)
            }
    }
}
