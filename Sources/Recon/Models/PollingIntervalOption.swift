import Foundation

enum PollingIntervalOption: Int, CaseIterable, Identifiable, Sendable {
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60
    case manual = -1
    case legacyFiveMinutes = 300
    case legacyFifteenMinutes = 900
    case legacyThirtyMinutes = 1800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tenSeconds:
            return "10s"
        case .thirtySeconds:
            return "30s"
        case .sixtySeconds:
            return "60s"
        case .manual:
            return "Manual"
        case .legacyFiveMinutes:
            return "Legacy: 5m"
        case .legacyFifteenMinutes:
            return "Legacy: 15m"
        case .legacyThirtyMinutes:
            return "Legacy: 30m"
        }
    }

    var helpText: String {
        switch self {
        case .manual:
            return "Manual refresh only. Background polling is disabled."
        case .legacyFiveMinutes, .legacyFifteenMinutes, .legacyThirtyMinutes:
            return "This legacy interval is still honored until you choose a new value."
        default:
            return "Refreshes status automatically in the background."
        }
    }

    var duration: Duration? {
        switch self {
        case .manual:
            return nil
        default:
            return .seconds(rawValue)
        }
    }

    var isLegacy: Bool {
        switch self {
        case .legacyFiveMinutes, .legacyFifteenMinutes, .legacyThirtyMinutes:
            return true
        default:
            return false
        }
    }

    static let defaultValue: PollingIntervalOption = .sixtySeconds
    static let supportedChoices: [PollingIntervalOption] = [.tenSeconds, .thirtySeconds, .sixtySeconds, .manual]

    static func restored(from rawValue: Int?) -> PollingIntervalOption {
        guard let rawValue, let option = PollingIntervalOption(rawValue: rawValue) else {
            return defaultValue
        }

        return option
    }

    static func displayChoices(including currentValue: PollingIntervalOption) -> [PollingIntervalOption] {
        if currentValue.isLegacy {
            return [currentValue] + supportedChoices
        }

        return supportedChoices
    }
}
