import Foundation

enum PodStatusTextNormalizer {
    static func normalize(_ rawStatus: String) -> String {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "Unknown"
        }

        switch trimmed {
        case "ErrImagePull":
            return "ImagePullBackOff"
        case "Completed":
            return "Completed"
        case "CrashLoopBackOff":
            return "CrashLoopBackOff"
        case "ImagePullBackOff":
            return "ImagePullBackOff"
        case "CreateContainerConfigError":
            return "CreateContainerConfigError"
        case "Running":
            return "Running"
        case "Pending":
            return "Pending"
        case "Unknown":
            return "Unknown"
        default:
            return trimmed
        }
    }

    static func healthBucket(
        for statusText: String,
        readyCount: Int,
        totalCount: Int
    ) -> ResourceHealthBucket {
        switch normalize(statusText) {
        case "Completed":
            return .neutral
        case "CrashLoopBackOff", "CreateContainerConfigError", "Error", "Failed":
            return .unhealthy
        case "ImagePullBackOff", "Pending", "Unknown":
            return .transitional
        case "Running":
            if totalCount > 0, readyCount == totalCount {
                return .healthy
            }
            return .transitional
        default:
            if totalCount > 0, readyCount == totalCount {
                return .healthy
            }
            return .transitional
        }
    }
}
