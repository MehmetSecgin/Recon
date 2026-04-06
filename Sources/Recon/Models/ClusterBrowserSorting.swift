import Foundation

enum ClusterBrowserSortDirection: Hashable {
    case ascending
    case descending

    func apply<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool {
        switch self {
        case .ascending:
            return lhs < rhs
        case .descending:
            return lhs > rhs
        }
    }
}

enum PodSortMode: Hashable {
    case defaultHealth
    case name(ClusterBrowserSortDirection)
    case status(ClusterBrowserSortDirection)
    case ready(ClusterBrowserSortDirection)
    case restarts(ClusterBrowserSortDirection)
    case age(ClusterBrowserSortDirection)
}

enum DeploymentSortMode: Hashable {
    case defaultHealth
    case name(ClusterBrowserSortDirection)
    case ready(ClusterBrowserSortDirection)
    case updated(ClusterBrowserSortDirection)
    case available(ClusterBrowserSortDirection)
    case age(ClusterBrowserSortDirection)
}

enum ServiceSortMode: Hashable {
    case name(ClusterBrowserSortDirection)
    case type(ClusterBrowserSortDirection)
    case clusterIP(ClusterBrowserSortDirection)
    case age(ClusterBrowserSortDirection)
}

enum ConfigMapSortMode: Hashable {
    case name(ClusterBrowserSortDirection)
    case keyCount(ClusterBrowserSortDirection)
    case age(ClusterBrowserSortDirection)
}

enum ClusterBrowserSorting {
    static func sortPods(_ pods: [PodResource], using mode: PodSortMode) -> [PodResource] {
        pods.sorted { lhs, rhs in
            switch mode {
            case .defaultHealth:
                return compare(
                    lhs.statusSortValue,
                    rhs.statusSortValue,
                    lhs.name,
                    rhs.name
                )
            case .name(let direction):
                return compare(lhs.name, rhs.name, direction: direction, fallback: {
                    compare(lhs.statusSortValue, rhs.statusSortValue, lhs.name, rhs.name)
                })
            case .status(let direction):
                return compare(lhs.statusSortValue, rhs.statusSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.readySortValue, rhs.readySortValue)
                })
            case .ready(let direction):
                return compare(lhs.readySortValue, rhs.readySortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.restartCount, rhs.restartCount)
                })
            case .restarts(let direction):
                return compare(lhs.restartCount, rhs.restartCount, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.statusSortValue, rhs.statusSortValue)
                })
            case .age(let direction):
                return compare(lhs.ageSortValue, rhs.ageSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.statusSortValue, rhs.statusSortValue)
                })
            }
        }
    }

    static func sortDeployments(_ deployments: [DeploymentResource], using mode: DeploymentSortMode) -> [DeploymentResource] {
        deployments.sorted { lhs, rhs in
            switch mode {
            case .defaultHealth:
                return compare(
                    lhs.defaultHealthSortValue,
                    rhs.defaultHealthSortValue,
                    lhs.name,
                    rhs.name
                )
            case .name(let direction):
                return compare(lhs.name, rhs.name, direction: direction, fallback: {
                    compare(lhs.defaultHealthSortValue, rhs.defaultHealthSortValue, lhs.name, rhs.name)
                })
            case .ready(let direction):
                return compare(lhs.defaultHealthSortValue, rhs.defaultHealthSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.readySortValue, rhs.readySortValue)
                })
            case .updated(let direction):
                return compare(lhs.updatedReplicas, rhs.updatedReplicas, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.defaultHealthSortValue, rhs.defaultHealthSortValue)
                })
            case .available(let direction):
                return compare(lhs.availableReplicas, rhs.availableReplicas, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.defaultHealthSortValue, rhs.defaultHealthSortValue)
                })
            case .age(let direction):
                return compare(lhs.ageSortValue, rhs.ageSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.defaultHealthSortValue, rhs.defaultHealthSortValue)
                })
            }
        }
    }

    static func sortServices(_ services: [ServiceResource], using mode: ServiceSortMode) -> [ServiceResource] {
        services.sorted { lhs, rhs in
            switch mode {
            case .name(let direction):
                return compare(lhs.name, rhs.name, direction: direction, fallback: {
                    compare(lhs.type, rhs.type, lhs.clusterIPSortValue, rhs.clusterIPSortValue)
                })
            case .type(let direction):
                return compare(lhs.type, rhs.type, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.clusterIPSortValue, rhs.clusterIPSortValue)
                })
            case .clusterIP(let direction):
                return compare(lhs.clusterIPSortValue, rhs.clusterIPSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.type, rhs.type)
                })
            case .age(let direction):
                return compare(lhs.ageSortValue, rhs.ageSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.type, rhs.type)
                })
            }
        }
    }

    static func sortConfigMaps(_ configMaps: [ConfigMapResource], using mode: ConfigMapSortMode) -> [ConfigMapResource] {
        configMaps.sorted { lhs, rhs in
            switch mode {
            case .name(let direction):
                return compare(lhs.name, rhs.name, direction: direction, fallback: {
                    compare(lhs.dataKeyCount, rhs.dataKeyCount, lhs.ageSortValue, rhs.ageSortValue)
                })
            case .keyCount(let direction):
                return compare(lhs.dataKeyCount, rhs.dataKeyCount, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.ageSortValue, rhs.ageSortValue)
                })
            case .age(let direction):
                return compare(lhs.ageSortValue, rhs.ageSortValue, direction: direction, fallback: {
                    compare(lhs.name, rhs.name, lhs.dataKeyCount, rhs.dataKeyCount)
                })
            }
        }
    }

    static func retainedSelection(selectedID: String?, visibleIDs: [String]) -> String? {
        guard let selectedID else {
            return nil
        }

        return visibleIDs.contains(selectedID) ? selectedID : nil
    }

    private static func compare<T: Comparable>(
        _ lhs: T,
        _ rhs: T,
        direction: ClusterBrowserSortDirection = .ascending,
        fallback: () -> Bool
    ) -> Bool {
        if lhs == rhs {
            return fallback()
        }

        return direction.apply(lhs, rhs)
    }

    private static func compare<A: Comparable, B: Comparable>(
        _ lhsA: A,
        _ rhsA: A,
        _ lhsB: B,
        _ rhsB: B
    ) -> Bool {
        if lhsA != rhsA {
            return lhsA < rhsA
        }

        return lhsB < rhsB
    }

    private static func compare<A: Comparable, B: Comparable, C: Comparable>(
        _ lhsA: A,
        _ rhsA: A,
        _ lhsB: B,
        _ rhsB: B,
        _ lhsC: C,
        _ rhsC: C
    ) -> Bool {
        if lhsA != rhsA {
            return lhsA < rhsA
        }

        if lhsB != rhsB {
            return lhsB < rhsB
        }

        return lhsC < rhsC
    }
}
