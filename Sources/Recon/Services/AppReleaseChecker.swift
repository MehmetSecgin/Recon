import Foundation

struct AppReleaseChecker {
    enum ReleaseError: Error {
        case invalidRepository
        case invalidResponse
        case unexpectedStatusCode(Int)
        case invalidReleasePayload
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private let session: URLSession
    private let repository: String
    private let assetName: String
    private let userAgent: String

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        self.session = session
        repository = (bundle.object(forInfoDictionaryKey: "ReconGitHubRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "mehmetsecgin/Recon"
        assetName = (bundle.object(forInfoDictionaryKey: "ReconReleaseAssetName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Recon.app.zip"

        let bundleName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "Recon"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "unknown"
        userAgent = "\(bundleName)/\(version)"
    }

    func fetchLatestRelease() async throws -> AppRelease {
        guard repository.contains("/") else {
            throw ReleaseError.invalidRepository
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw ReleaseError.invalidRepository
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReleaseError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ReleaseError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let normalizedVersion = Self.normalizedVersion(from: release.tagName) else {
            throw ReleaseError.invalidReleasePayload
        }

        let assetDownloadURL = release.assets.first { $0.name == assetName }?.browserDownloadURL

        return AppRelease(
            version: normalizedVersion,
            tagName: release.tagName,
            releasePageURL: release.htmlURL,
            assetDownloadURL: assetDownloadURL
        )
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateVersion = SemanticVersion(candidate),
              let currentVersion = SemanticVersion(current) else {
            return false
        }

        return candidateVersion > currentVersion
    }

    static func normalizedVersion(from rawValue: String) -> String? {
        SemanticVersion(rawValue)?.description
    }
}

private struct SemanticVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let coreVersion = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? withoutPrefix

        let parsedComponents = coreVersion
            .split(separator: ".")
            .compactMap { component -> Int? in
                let digits = component.prefix { $0.isNumber }
                guard !digits.isEmpty else { return nil }
                return Int(digits)
            }

        guard !parsedComponents.isEmpty else { return nil }
        components = parsedComponents
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)

        for index in 0 ..< count {
            let left = lhs.components[safe: index] ?? 0
            let right = rhs.components[safe: index] ?? 0

            if left != right {
                return left < right
            }
        }

        return false
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
