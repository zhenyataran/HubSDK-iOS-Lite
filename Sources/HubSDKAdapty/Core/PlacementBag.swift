import Adapty
import Foundation

// MARK: - PlacementBag

/// A thread-safe container for paywall placements with lazy loading support.
public final class PlacementBag: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let lock = NSLock()
    private var entries: [PlacementEntry] = []
    private var loadedIds: Set<String> = []
    private let locale: String
    
    // MARK: - Initialization
    
    public init(_ identifiers: [String], locale: String) async {
        self.locale = locale
        
        guard !identifiers.isEmpty else { return }
        
        let loaded = await Self.fetchEntries(for: identifiers, locale: locale)

        addEntries(loaded, ids: loaded.map(\.placementId))
    }

    // MARK: - Loading

    /// Loads the given placements, skipping ones already loaded.
    ///
    /// A placement that fails to fetch (e.g. not yet configured in the dashboard)
    /// is skipped rather than aborting the others — each placement is independent.
    @discardableResult
    public func load(_ identifiers: [String]) async -> [PlacementEntry] {
        let newIds = filterNewIds(identifiers)
        guard !newIds.isEmpty else { return [] }

        let loaded = await Self.fetchEntries(for: newIds, locale: locale)

        addEntries(loaded, ids: loaded.map(\.placementId))

        return loaded
    }
    
    public func loadIfNeeded(_ identifier: String) async throws -> PlacementEntry {
        if let existing = entry(for: identifier) {
            return existing
        }

        let loaded = await load([identifier])

        guard let entry = loaded.first else {
            throw HubSDKError.placementNotFound(identifier)
        }

        return entry
    }
    
    // MARK: - Sync Access (Thread-Safe)
    
    public func isLoaded(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedIds.contains(identifier)
    }
    
    public func entry(for placementId: String) -> PlacementEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.placementId == placementId }
    }
    
    public var allEntries: [PlacementEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    
    public var placementIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadedIds)
    }
    
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
    
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }
    
    // MARK: - Private Sync Helpers
    
    private func filterNewIds(_ identifiers: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers.filter { !loadedIds.contains($0) }
    }
    
    private func addEntries(_ newEntries: [PlacementEntry], ids: [String]) {
        lock.lock()
        entries.append(contentsOf: newEntries)
        loadedIds.formUnion(ids)
        lock.unlock()
    }
    
    // MARK: - Static Fetch (No Lock)

    /// Fetches each placement independently — a placement that isn't configured yet
    /// (or otherwise fails to fetch) is logged and skipped rather than aborting the rest.
    private static func fetchEntries(for identifiers: [String], locale: String) async -> [PlacementEntry] {
        var result: [PlacementEntry] = []
        result.reserveCapacity(identifiers.count)

        for id in identifiers {
            do {
                let flow = try await Adapty.getFlow(placementId: id)
                let products = try await Adapty.getPaywallProducts(flow: flow)

                // Flow carries per-locale remote configs; pick the requested locale, fall back to the first one.
                let remoteConfig = flow.remoteConfigs.first { $0.locale.lowercased() == locale.lowercased() }
                    ?? flow.remoteConfigs.first
                let remoteConfigData = remoteConfig?.jsonString.data(using: .utf8)

                let viewType: AdaptyPaywallViewType = {
                    if flow.hasViewConfiguration {
                        return .builder
                    }

                    let identifier = (remoteConfig?.dictionary?["identifier"] as? String)
                        ?? flow.name.components(separatedBy: "-").first?.lowercased()
                        ?? ""

                    return .local(identifier)
                }()

                result.append(PlacementEntry(
                    placementId: id,
                    identifier: viewType,
                    flow: flow,
                    products: products,
                    remoteConfigData: remoteConfigData
                ))
            } catch {
                HubSDKError.buildPlacementEntryFailed(error).log()
            }
        }

        return result
    }
}

// MARK: - Sequence Conformance

extension PlacementBag: Sequence {
    public func makeIterator() -> IndexingIterator<[PlacementEntry]> {
        allEntries.makeIterator()
    }
}

// MARK: - Collection Convenience

extension PlacementBag {
    
    public subscript(placementId: String) -> PlacementEntry? {
        entry(for: placementId)
    }
    
    public func entries(where predicate: (PlacementEntry) -> Bool) -> [PlacementEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter(predicate)
    }
    
    public var builderEntries: [PlacementEntry] {
        entries(where: { $0.identifier == .builder })
    }
    
    public var localEntries: [PlacementEntry] {
        entries(where: {
            if case .local = $0.identifier { return true }
            return false
        })
    }
}
