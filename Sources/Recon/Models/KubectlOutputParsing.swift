import Foundation

enum KubectlConfigOutputParsing {
    struct TargetFields: Equatable {
        let context: String?
        let namespace: String?
    }

    struct ContextEntry: Equatable {
        let name: String
        let namespace: String?
    }

    static func parseTargetFields(from output: String) -> TargetFields {
        let line = firstNonEmptyLine(in: output)
        guard let line else {
            return TargetFields(context: nil, namespace: nil)
        }

        let fields = line
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

        return TargetFields(
            context: fields.first ?? nil,
            namespace: fields.count > 1 ? fields[1] : nil
        )
    }

    static func parseContextEntries(from output: String) -> [ContextEntry] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.isEmpty == false else {
                    return nil
                }

                let fields = trimmedLine
                    .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }

                guard let name = fields.first ?? nil else {
                    return nil
                }

                return ContextEntry(
                    name: name,
                    namespace: fields.count > 1 ? fields[1] : nil
                )
            }
    }

    private static func firstNonEmptyLine(in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }
}

enum KubectlAgeParser {
    static func sortValue(for ageText: String) -> Int {
        let trimmed = ageText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else {
            return 0
        }

        let pattern = #"^(\d+)([smhdwy])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              match.numberOfRanges == 3,
              let magnitudeRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed),
              let magnitude = Int(trimmed[magnitudeRange]) else {
            return 0
        }

        let unit = trimmed[unitRange]
        let multiplier: Int

        switch unit {
        case "s":
            multiplier = 1
        case "m":
            multiplier = 60
        case "h":
            multiplier = 60 * 60
        case "d":
            multiplier = 60 * 60 * 24
        case "w":
            multiplier = 60 * 60 * 24 * 7
        case "y":
            multiplier = 60 * 60 * 24 * 365
        default:
            multiplier = 0
        }

        return -(magnitude * multiplier)
    }
}

enum KubectlTableParsingError: LocalizedError {
    case invalidRow(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let line):
            return "Couldn't parse kubectl table row: \(line)"
        }
    }
}

enum KubectlTableParser {
    static func parsePods(from output: String, namespace: String) throws -> [PodResource] {
        try resourceLines(from: output).map { line in
            let columns = splitColumns(in: line)
            guard columns.count >= 5 else {
                throw KubectlTableParsingError.invalidRow(line)
            }

            let ready = try parseReadyCounts(columns[1], line: line)
            let ageText = columns[4]
            return PodResource(
                id: "pod:\(namespace):\(columns[0])",
                name: columns[0],
                namespace: namespace,
                statusText: PodStatusTextNormalizer.normalize(columns[2]),
                readyCount: ready.readyCount,
                totalCount: ready.totalCount,
                restartCount: parseRestartCount(columns[3]),
                ageText: ageText,
                ageSortValue: KubectlAgeParser.sortValue(for: ageText)
            )
        }
    }

    static func parseDeployments(from output: String, namespace: String) throws -> [DeploymentResource] {
        try resourceLines(from: output).map { line in
            let columns = splitColumns(in: line)
            guard columns.count >= 5 else {
                throw KubectlTableParsingError.invalidRow(line)
            }

            let ready = try parseReadyCounts(columns[1], line: line)
            let ageText = columns[4]

            return DeploymentResource(
                id: "deployment:\(namespace):\(columns[0])",
                name: columns[0],
                namespace: namespace,
                readyReplicas: ready.readyCount,
                desiredReplicas: ready.totalCount,
                updatedReplicas: parseInt(columns[2]),
                availableReplicas: parseInt(columns[3]),
                ageText: ageText,
                ageSortValue: KubectlAgeParser.sortValue(for: ageText)
            )
        }
    }

    static func parseServices(from output: String, namespace: String) throws -> [ServiceResource] {
        try resourceLines(from: output).map { line in
            let columns = splitColumns(in: line)
            guard columns.count >= 5 else {
                throw KubectlTableParsingError.invalidRow(line)
            }

            let portsIndex = columns.count >= 6 ? columns.count - 2 : 3
            let ageText = columns.last ?? ""

            return ServiceResource(
                id: "service:\(namespace):\(columns[0])",
                name: columns[0],
                namespace: namespace,
                type: columns[1],
                clusterIP: columns[2] == "<none>" ? nil : columns[2],
                portsText: columns[portsIndex],
                ageText: ageText,
                ageSortValue: KubectlAgeParser.sortValue(for: ageText)
            )
        }
    }

    static func parseConfigMaps(from output: String, namespace: String) throws -> [ConfigMapResource] {
        try resourceLines(from: output).map { line in
            let columns = splitColumns(in: line)
            guard columns.count >= 3 else {
                throw KubectlTableParsingError.invalidRow(line)
            }

            let ageText = columns[2]
            return ConfigMapResource(
                id: "configmap:\(namespace):\(columns[0])",
                name: columns[0],
                namespace: namespace,
                dataKeyCount: parseInt(columns[1]),
                ageText: ageText,
                ageSortValue: KubectlAgeParser.sortValue(for: ageText)
            )
        }
    }

    static func parseRestartCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(separator: " ").first else {
            return 0
        }

        return Int(token) ?? 0
    }

    private static func resourceLines(from output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func splitColumns(in line: String) -> [String] {
        line
            .replacingOccurrences(of: #"\s{2,}"#, with: "\t", options: .regularExpression)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func parseReadyCounts(_ text: String, line: String) throws -> (readyCount: Int, totalCount: Int) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let readyCount = Int(parts[0]),
              let totalCount = Int(parts[1]) else {
            throw KubectlTableParsingError.invalidRow(line)
        }

        return (readyCount, totalCount)
    }

    private static func parseInt(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
