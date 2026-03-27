import Foundation

enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String, latestVersion: String?)
    case available(AppRelease)
    case installing(AppRelease)
    case checkFailed(currentVersion: String)
    case installFailed(currentVersion: String, release: AppRelease)
}
