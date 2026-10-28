import Foundation
import Observation
import VMCore
import VMStorage

/// Keeps the search index in step with the library and runs the Search page's
/// query. The query and results live here, not in the page, so they're still
/// there after opening a meeting from the results and coming back.
@Observable
@MainActor
final class SearchService {
    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    /// What the Search page is asking; changing it re-runs the search.
    var query = SearchQuery() {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var results: SearchResults = .empty
    private(set) var isSearching = false
    /// Filter menu values (people, speakers, orgs, labels), refreshed after each sync.
    private(set) var facets = SearchFacets()
    /// Set while a sync with a lot to do (the first build, a new library) is running.
    private(set) var indexing: Progress?
    /// The index has been brought up to date at least once since launch.
    private(set) var isReady = false
    private(set) var lastError: String?

    @ObservationIgnored private let index: SearchIndex
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Syncs with fewer meetings to (re)index than this don't show progress.
    private static let progressThreshold = 10

    init(databaseURL: URL = SearchIndex.defaultURL) {
        index = SearchIndex(databaseURL: databaseURL)
    }

    /// The library changed on disk. Syncs straight away the first time, then after
    /// a short pause so a burst of writes (a recording, a summary streaming in)
    /// costs one pass.
    func libraryChanged(tree: FolderNode?, root: URL) {
        guard let tree else { return }
        syncTask?.cancel()
        let delay: Duration = isReady ? .milliseconds(1500) : .zero
        let threshold = Self.progressThreshold
        syncTask = Task { [index] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            do {
                let stats = try await index.sync(tree: tree, root: root) { done, total in
                    guard total >= threshold else { return }
                    Task { @MainActor [weak self] in
                        self?.indexing = done < total ? Progress(done: done, total: total) : nil
                    }
                }
                guard !Task.isCancelled else { return }
                indexing = nil
                lastError = nil
                facets = (try? await index.facets()) ?? facets
                isReady = true
                if stats.indexed > 0 || stats.removed > 0 { scheduleSearch(debounce: false) }
            } catch {
                indexing = nil
                lastError = "Couldn't update the search index: \(error)"
            }
        }
    }

    /// Show the meetings in `folderPath` (relative to the root, "Clients/Acme"), keeping the words.
    func scope(toFolder folderPath: String?) {
        query.filters = SearchFilters()
        query.filters.folderPath = folderPath
    }

    func clearFilters() {
        query.filters = SearchFilters()
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let query = query
        guard !query.isBlank else {
            results = .empty
            isSearching = false
            return
        }
        searchTask = Task { [index] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            defer { if !Task.isCancelled { isSearching = false } }
            do {
                let found = try await index.search(query)
                guard !Task.isCancelled else { return }
                results = found
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = .empty
                lastError = "Search failed: \(error)"
            }
        }
    }
}
