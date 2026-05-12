import Foundation
import Observation

/// Checks GitHub Releases for a newer version of the app.
/// Set `githubRepo` to the "owner/repo" string (e.g. "timcoysh/vibe-meetings").
@Observable
@MainActor
final class UpdateChecker {
    private static let repoKey = "VibeMeetings.GitHubRepo"
    private static let dismissedVersionKey = "VibeMeetings.DismissedUpdateVersion"

    /// GitHub "owner/repo" — configured in Settings.
    var githubRepo: String {
        didSet { UserDefaults.standard.set(githubRepo, forKey: Self.repoKey) }
    }

    /// Latest available release info, if newer than the running version.
    private(set) var availableUpdate: GitHubRelease?

    /// Whether the check is in progress.
    private(set) var isChecking = false

    /// Error from the last check, if any.
    private(set) var checkError: String?

    struct GitHubRelease: Sendable {
        let tagName: String
        let version: String
        let htmlURL: URL
        let body: String
        let publishedAt: Date?
    }

    init() {
        self.githubRepo = UserDefaults.standard.string(forKey: Self.repoKey) ?? ""
    }

    /// Check GitHub for a newer release. Safe to call multiple times; no-ops if
    /// already checking or the repo is not configured.
    func checkForUpdates() async {
        let repo = githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, repo.contains("/") else { return }
        guard !isChecking else { return }

        isChecking = true
        checkError = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease(repo: repo)
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            if isNewer(release.version, than: currentVersion) {
                // Don't show if user dismissed this exact version.
                let dismissed = UserDefaults.standard.string(forKey: Self.dismissedVersionKey)
                if dismissed != release.version {
                    availableUpdate = release
                }
            } else {
                availableUpdate = nil
            }
        } catch {
            checkError = error.localizedDescription
        }
    }

    /// User chose to dismiss this version's update notification.
    func dismissUpdate() {
        if let ver = availableUpdate?.version {
            UserDefaults.standard.set(ver, forKey: Self.dismissedVersionKey)
        }
        availableUpdate = nil
    }

    // MARK: - GitHub API

    private func fetchLatestRelease(repo: String) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.apiError("GitHub returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let json = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let version = json.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        return GitHubRelease(
            tagName: json.tag_name,
            version: version,
            htmlURL: json.html_url,
            body: json.body ?? "",
            publishedAt: ISO8601DateFormatter().date(from: json.published_at ?? "")
        )
    }

    /// Simple semver comparison: "1.2.0" > "1.1.0".
    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case apiError(String)
        var errorDescription: String? {
            switch self { case .apiError(let msg): return msg }
        }
    }

    private struct GitHubReleaseResponse: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let published_at: String?
    }
}
