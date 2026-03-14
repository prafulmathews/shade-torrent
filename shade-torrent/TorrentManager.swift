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
    var progress: Float = 0     // 0.0 – 1.0
    var isSelected: Bool = true // false = dont_download priority
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
    var savePath: String = ""
    var scopedURL: URL? = nil   // non-nil when a custom folder was picked via NSOpenPanel
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

    // Unified preview state (both .torrent files and magnet links)
    var previewInfo: TorrentFileInfo?       // nil = magnet still loading
    var isFetchingPreview: Bool = false     // true while waiting for magnet metadata
    var previewSavePath: String = ""        // user-editable save location
    var previewScopedURL: URL? = nil        // security-scoped URL when user picked a custom folder
    var previewSelectedFiles: Set<Int> = [] // indices of files the user wants to download
    private var currentPreviewIndex: Int = -1          // magnet handle index, -1 for .torrent
    private var pendingTorrentInfo: TorrentFileInfo?   // stored for .torrent confirm

    private var pollTask: Task<Void, Never>?

    init() {
        startPolling()
    }

    func startTorrentFilePreview(from url: URL) {
        let info: TorrentFileInfo
        do {
            info = try TorrentBridge.shared().parseTorrentFile(url.path)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        pendingTorrentInfo = info
        previewInfo = info
        previewSelectedFiles = Set(0..<info.files.count)
        isFetchingPreview = false
        currentPreviewIndex = -1
        previewSavePath = defaultSavePath()
    }

    func startMagnetPreview(uri: String) {
        let savePath = defaultSavePath()
        var err: NSError?
        let idx = TorrentBridge.shared().addMagnet(forPreview: uri, savePath: savePath, error: &err)
        if let e = err {
            errorMessage = e.localizedDescription
            return
        }
        if idx < 0 {
            errorMessage = "Failed to stage magnet link"
            return
        }

        currentPreviewIndex = idx
        pendingTorrentInfo = nil
        previewInfo = nil
        previewSavePath = savePath
        isFetchingPreview = true
    }

    func confirmPreviewDownload() {
        guard let info = previewInfo else { return }

        if currentPreviewIndex >= 0 {
            // Magnet flow: promote the preview handle
            do {
                try TorrentBridge.shared().startPreviewDownload(currentPreviewIndex, savePath: previewSavePath)
            } catch {
                errorMessage = error.localizedDescription
                resetPreview()
                return
            }
        } else if let torrentInfo = pendingTorrentInfo {
            // .torrent file flow: start download with chosen save path
            do {
                try TorrentBridge.shared().startDownload(torrentInfo, savePath: previewSavePath)
            } catch {
                errorMessage = error.localizedDescription
                resetPreview()
                return
            }
        } else {
            return
        }

        // Activate sandbox access for the custom folder; keep it alive for the download
        _ = previewScopedURL?.startAccessingSecurityScopedResource()

        var item = TorrentItem(
            name: info.name,
            totalSize: info.totalSize,
            filePath: info.filePath,
            files: info.files.map { TorrentFile(name: $0.name, size: $0.size) }
        )
        item.savePath = previewSavePath
        item.scopedURL = previewScopedURL
        torrents.append(item)

        // Apply file selection priorities if not all files were selected
        let handleIndex = torrents.count - 1
        if previewSelectedFiles.count < info.files.count {
            let selected = previewSelectedFiles.map { NSNumber(value: $0) }
            TorrentBridge.shared().setFilePriorities(selected, forHandleAt: handleIndex)
        }

        resetPreview()
    }

    func cancelPreview() {
        if currentPreviewIndex >= 0 {
            TorrentBridge.shared().cancelPreview(currentPreviewIndex)
        }
        resetPreview()
    }

    private func resetPreview() {
        previewInfo = nil
        pendingTorrentInfo = nil
        previewScopedURL = nil
        previewSelectedFiles = []
        currentPreviewIndex = -1
        isFetchingPreview = false
    }

    private func defaultSavePath() -> String {
        FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path ?? NSHomeDirectory()
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

    func toggleFile(torrentID: UUID, fileIndex: Int) {
        guard let ti = torrents.firstIndex(where: { $0.id == torrentID }),
              fileIndex < torrents[ti].files.count else { return }
        let nowSelected = !torrents[ti].files[fileIndex].isSelected
        torrents[ti].files[fileIndex].isSelected = nowSelected
        TorrentBridge.shared().setFileSelected(nowSelected, atFileIndex: fileIndex, forHandleAt: ti)
    }

    func remove(id: UUID, deleteData: Bool) {
        guard let index = torrents.firstIndex(where: { $0.id == id }) else { return }
        torrents[index].scopedURL?.stopAccessingSecurityScopedResource()
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
                if previewInfo == nil {
                    previewSelectedFiles = Set(0..<info.files.count)
                }
                previewInfo = info
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
            if st.metadataReady, let files = st.resolvedFiles, torrents[i].files.isEmpty {
                if let name = st.resolvedName { torrents[i].name = name }
                torrents[i].totalSize = st.resolvedTotalSize
                torrents[i].files = files.map { TorrentFile(name: $0.name, size: $0.size) }
            }

            // Per-file progress
            if let progresses = st.fileProgress {
                for (j, p) in progresses.enumerated() {
                    guard j < torrents[i].files.count else { break }
                    torrents[i].files[j].progress = p.floatValue
                }
            }

            // Per-file selection (sync from libtorrent so external changes are reflected)
            if let priorities = st.filePriorities {
                for (j, p) in priorities.enumerated() {
                    guard j < torrents[i].files.count else { break }
                    torrents[i].files[j].isSelected = p.intValue > 0
                }
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
