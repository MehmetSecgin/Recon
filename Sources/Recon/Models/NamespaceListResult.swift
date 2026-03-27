import Foundation

struct NamespaceListResult: Equatable {
    var available: [String]
    var recentlyUsed: [String]
    var kubeconfigDefault: String
    var currentOverride: String?
    var clusterQueryFailed: Bool
}
