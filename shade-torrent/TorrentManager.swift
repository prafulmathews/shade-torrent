//
//  TorrentManager.swift
//  shade-torrent
//

import Foundation

// MARK: - Models

enum DownloadState: Equatable {
    case queued, checking, downloading, finished, seeding
    case error(String)

    var label: String {
        switch self {
        case .queued:           return "Queued"
        case .checking:         return "Checking"
        case .downloading:      return "Downloading"
        case .finished:         return "Finished"
        case .seeding:          return "Seeding"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        if case .downloading = self { return true }
        if case .checking = self { return true }
        return false
    }
}

struct TorrentFile: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
}

struct TorrentItem: Identifiable {
    let id = UUID()
    var name: String
    var totalSize: Int64
    let filePath: String
    var files: [TorrentFile]
    // Updated by the polling timer
    var progress: Float = 0
    var downloadRate: Int = 0
    var uploadRate: Int = 0
    var totalDone: Int64 = 0
    var state: DownloadState = .queued
    var isPaused: Bool = false
    var isStopped: Bool = false
    var numSeeds: Int = 0
    var numPeers: Int = 0
    var listSeeds: Int = 0
    var listPeers: Int = 0

    var statusLabel: String {
        if isStopped { return "Stopped" }
        if isPaused  { return "Paused" }
        return state.label
    }
}

// MARK: - TorrentManager

@MainActor
@Observable
class TorrentManager {
    var torrents: [TorrentItem] = []
    var errorMessage: String?

    // Magnet preview state
    var previewInfo: TorrentFileInfo?
    var isFetchingPreview: Bool = false
    private var currentPreviewIndex: Int = -1
    private var previewSavePath: String = ""

    private var pollTask: Task<Void, Never>?

    init() {
        startPolling()
    }

    func addTorrent(from url: URL) {
        let bridge = TorrentBridge.shared()

        let info: TorrentFileInfo
        do {
            info = try bridge.parseTorrentFile(url.path)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let savePath = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path ?? NSHomeDirectory()

        do {
            try bridge.startDownload(info, savePath: savePath)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let files = info.files.map { TorrentFile(name: $0.name, size: $0.size) }
        torrents.append(TorrentItem(
            name: info.name,
            totalSize: info.totalSize,
            filePath: info.filePath,
            files: files
        ))
    }

    func startMagnetPreview(uri: String) {
        let bridge = TorrentBridge.shared()
        let savePath = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path ?? NSHomeDirectory()

        var err: NSError?
        let idx = bridge.addMagnet(forPreview: uri, savePath: savePath, error: &err)
        if let e = err {
            errorMessage = e.localizedDescription
            return
        }
        if idx < 0 {
            errorMessage = "Failed to stage magnet link"
            return
        }

        currentPreviewIndex = idx
        previewSavePath = savePath
        previewInfo = nil
        isFetchingPreview = true
    }

    func confirmPreviewDownload() {
        guard currentPreviewIndex >= 0, let info = previewInfo else { return }
        let bridge = TorrentBridge.shared()

        do {
            try bridge.startPreviewDownload(currentPreviewIndex)
        } catch {
            errorMessage = error.localizedDescription
            isFetchingPreview = false
            currentPreviewIndex = -1
            previewInfo = nil
            return
        }

        torrents.append(TorrentItem(
            name: info.name,
            totalSize: info.totalSize,
            filePath: info.filePath,
            files: info.files.map { TorrentFile(name: $0.name, size: $0.size) }
        ))

        isFetchingPreview = false
        currentPreviewIndex = -1
        previewInfo = nil
    }

    func cancelPreview() {
        if currentPreviewIndex >= 0 {
            TorrentBridge.shared().cancelPreview(currentPreviewIndex)
        }
        isFetchingPreview = false
        currentPreviewIndex = -1
        previewInfo = nil
    }

    // MARK: - Controls

    func pause(id: UUID) {
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        TorrentBridge.shared().pauseTorrent(at: index)
    }

    func resume(id: UUID) {
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        TorrentBridge.shared().resumeTorrent(at: index)
        torrents[index].isPaused = false
        torrents[index].isStopped = false
    }

    func stop(id: UUID) {
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        TorrentBridge.shared().stopTorrent(at: index)
        torrents[index].isStopped = true
    }

    func remove(id: UUID, deleteData: Bool) {
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        TorrentBridge.shared().removeTorrent(at: index, deleteData: deleteData)
        torrents.remove(at: index)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.applyStatuses()
            }
        }
    }

    private func applyStatuses() {
        // Poll preview metadata when waiting for a magnet preview
        if isFetchingPreview, currentPreviewIndex >= 0 {
            if let info = TorrentBridge.shared().pollPreviewMetadata(currentPreviewIndex) {
                previewInfo = info
                // Keep isFetchingPreview true so the sheet sees it's ready
            }
        }

        let statuses = TorrentBridge.shared().pollStatuses()
        for (i, st) in statuses.enumerated() {
            guard i < torrents.count else { break }
            torrents[i].progress     = st.progress
            torrents[i].downloadRate = Int(st.downloadRate)
            torrents[i].uploadRate   = Int(st.uploadRate)
            torrents[i].totalDone    = st.totalDone
            torrents[i].state        = mapState(st)
            torrents[i].isPaused     = st.paused
            torrents[i].numSeeds     = Int(st.numSeeds)
            torrents[i].numPeers     = Int(st.numPeers)
            torrents[i].listSeeds    = Int(st.listSeeds)
            torrents[i].listPeers    = Int(st.listPeers)
            // Apply metadata once it arrives from peers (magnet links)
            if st.metadataReady, let files = st.resolvedFiles {
                if let name = st.resolvedName { torrents[i].name = name }
                torrents[i].totalSize = st.resolvedTotalSize
                torrents[i].files = files.map { TorrentFile(name: $0.name, size: $0.size) }
            }
        }
    }

    private func mapState(_ st: TorrentStatus) -> DownloadState {
        if let msg = st.errorMessage { return .error(msg) }
        switch st.state {
        case .queued:       return .queued
        case .checking:     return .checking
        case .downloading:  return .downloading
        case .finished:     return .finished
        case .seeding:      return .seeding
        case .error:        return .error("Unknown error")
        @unknown default:   return .queued
        }
    }
}

// MARK: - Formatting helpers

extension Int64 {
    var formattedSize: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: "%.1f %@", value, units[i])
    }
}

extension Int {
    var formattedRate: String {
        Int64(self).formattedSize + "/s"
    }
}
