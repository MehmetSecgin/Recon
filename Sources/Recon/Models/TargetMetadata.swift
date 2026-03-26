import Foundation

enum KubeconfigMode: Equatable {
    case pinned
    case inheritedSingle
    case inheritedMultiple(count: Int)
    case `default`
    case unresolved
}

struct TargetMetadata: Equatable {
    let kubeconfigDisplay: String
    let kubeconfigMode: KubeconfigMode
    let context: String?
    let namespace: String?
    let isLastKnown: Bool
    let resolutionError: String?

    static let empty = TargetMetadata(
        kubeconfigDisplay: "\u{2014}",
        kubeconfigMode: .unresolved,
        context: nil,
        namespace: nil,
        isLastKnown: true,
        resolutionError: nil
    )

    var hasResolvedValues: Bool {
        context != nil || namespace != nil
    }

    func applying(
        context: String?,
        namespace: String?,
        isLastKnown: Bool,
        resolutionError: String?
    ) -> TargetMetadata {
        TargetMetadata(
            kubeconfigDisplay: kubeconfigDisplay,
            kubeconfigMode: kubeconfigMode,
            context: context,
            namespace: namespace,
            isLastKnown: isLastKnown,
            resolutionError: resolutionError
        )
    }
}
