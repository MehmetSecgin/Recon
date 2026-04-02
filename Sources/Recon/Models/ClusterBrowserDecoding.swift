import Foundation

enum KubernetesTimestampParser {
    static func parse(_ rawValue: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]

        return withFractionalSeconds.date(from: rawValue) ?? withoutFractionalSeconds.date(from: rawValue)
    }
}

enum ConfigMapResourceDecoder {
    private struct ResourceListResponse<Item: Decodable>: Decodable {
        let items: [Item]
    }

    private struct ConfigMapListItem: Decodable {
        struct Metadata: Decodable {
            let name: String
            let namespace: String?
            let creationTimestamp: Date?
        }

        let metadata: Metadata
        let data: [String: String]?
        let immutable: Bool?
    }

    static func decode(from data: Data, defaultNamespace: String) throws -> [ConfigMapResource] {
        try decoder.decode(ResourceListResponse<ConfigMapListItem>.self, from: data).items.map { item in
            let namespace = item.metadata.namespace ?? defaultNamespace
            return ConfigMapResource(
                id: "configmap:\(namespace):\(item.metadata.name)",
                name: item.metadata.name,
                namespace: namespace,
                dataKeyCount: item.data?.count ?? 0,
                isImmutable: item.immutable ?? false,
                createdAt: item.metadata.creationTimestamp
            )
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let date = KubernetesTimestampParser.parse(rawValue) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Kubernetes timestamp: \(rawValue)"
            )
        }
        return decoder
    }()
}
