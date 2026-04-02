import Foundation

enum PodStatusReasonDeriver {
    static func derive(from waitingReasons: [String?]) -> String? {
        let normalizedReasons = waitingReasons
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard normalizedReasons.isEmpty == false else {
            return nil
        }

        if normalizedReasons.contains("CrashLoopBackOff") {
            return "CrashLoopBackOff"
        }

        if normalizedReasons.contains("ImagePullBackOff") || normalizedReasons.contains("ErrImagePull") {
            return "ImagePullBackOff"
        }

        if normalizedReasons.contains("CreateContainerConfigError") {
            return "CreateContainerConfigError"
        }

        return normalizedReasons.first
    }
}
