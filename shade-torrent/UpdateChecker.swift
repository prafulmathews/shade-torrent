//
//  UpdateChecker.swift
//  shade-torrent
//

import Foundation
import AppKit

@MainActor
@Observable
final class UpdateChecker {

    var updateAvailable = false
    var latestVersion   = ""
    var noUpdateFound   = false
    var checkError: String?

    private let repoOwner = "prafulmathews"
    private let repoName  = "shade-torrent"

    private var releasesPageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }

    func checkForUpdates(silent: Bool = true) async {
        checkError    = nil
        noUpdateFound = false

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release   = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest    = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current   = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

            if latest.compare(current, options: .numeric) == .orderedDescending {
                latestVersion   = latest
                updateAvailable = true
            } else if !silent {
                noUpdateFound = true
            }
        } catch {
            if !silent { checkError = error.localizedDescription }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }
}

// MARK: - GitHub API models

private struct GitHubRelease: Codable {
    let tagName: String
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
