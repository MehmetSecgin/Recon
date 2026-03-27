import Foundation

struct AppRelease: Equatable, Sendable {
    let version: String
    let tagName: String
    let releasePageURL: URL
    let assetDownloadURL: URL?

    var primaryActionURL: URL {
        assetDownloadURL ?? releasePageURL
    }

    var displayVersion: String {
        "v\(version)"
    }
}
