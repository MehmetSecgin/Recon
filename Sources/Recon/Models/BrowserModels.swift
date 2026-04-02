import Foundation

struct BrowserContextDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let sourcePath: String
    let sourceBadge: String?
    let defaultNamespace: String?
    let isProductionLike: Bool
}

struct BrowserTarget: Hashable {
    let context: BrowserContextDescriptor
    let namespace: String
}

enum BrowserContextLoadState: Equatable {
    case idle
    case loadingNamespaces
    case loadedNamespaces([String])
    case failed(String)

    var namespaces: [String] {
        switch self {
        case .loadedNamespaces(let namespaces):
            return namespaces
        case .idle, .loadingNamespaces, .failed:
            return []
        }
    }

    var errorMessage: String? {
        switch self {
        case .failed(let message):
            return message
        case .idle, .loadingNamespaces, .loadedNamespaces:
            return nil
        }
    }
}

struct BrowserSourceStatus: Identifiable, Hashable {
    let path: String
    let statusText: String
    let errorMessage: String?
    let contextCount: Int?

    var id: String { path }

    var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    var isValid: Bool {
        errorMessage == nil
    }
}

struct BrowserContextCatalog: Equatable {
    let contexts: [BrowserContextDescriptor]
    let sourceStatuses: [BrowserSourceStatus]
}

enum BrowserContextIdentity {
    static func makeID(contextName: String, sourcePath: String) -> String {
        "\(sourcePath)#\(contextName)"
    }
}

enum BrowserNamespaceSelectionResolver {
    static func resolve(
        rememberedNamespace: String?,
        defaultNamespace: String?,
        fallbackNamespace: String = "default"
    ) -> String {
        rememberedNamespace?.nilIfEmpty ??
        defaultNamespace?.nilIfEmpty ??
        fallbackNamespace
    }
}

enum BrowserSidebarFiltering {
    static func matchesContext(
        _ context: BrowserContextDescriptor,
        loadState: BrowserContextLoadState,
        query: String
    ) -> Bool {
        let normalizedQuery = normalized(query)
        guard normalizedQuery.isEmpty == false else {
            return true
        }

        if matches(text: context.name, query: normalizedQuery) {
            return true
        }

        if matches(text: context.sourceBadge, query: normalizedQuery) {
            return true
        }

        if matches(text: context.sourcePath, query: normalizedQuery) {
            return true
        }

        return filteredNamespaces(from: loadState.namespaces, query: normalizedQuery).isEmpty == false
    }

    static func filteredNamespaces(from namespaces: [String], query: String) -> [String] {
        let normalizedQuery = normalized(query)
        guard normalizedQuery.isEmpty == false else {
            return namespaces
        }

        return namespaces.filter { matches(text: $0, query: normalizedQuery) }
    }

    private static func matches(text: String?, query: String) -> Bool {
        guard let text else {
            return false
        }

        return text.localizedCaseInsensitiveContains(query)
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
