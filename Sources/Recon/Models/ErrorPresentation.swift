import Foundation

struct ErrorPresentation: Equatable {
    let title: String
    let message: String
    let suggestion: String?
    let rawDetailPreview: String?
    let canCopyStatus: Bool
    let canOpenLogs: Bool
}
