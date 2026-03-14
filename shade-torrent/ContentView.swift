//
//  ContentView.swift
//  shade-torrent
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var manager = TorrentManager()
    @State private var isImporting = false
    @State private var selectedID: UUID?
    @State private var pendingDeleteID: PendingDelete?
    @State private var deleteFiles = false
    @State private var showMagnetSheet = false
    @State private var magnetURI = ""
    @State private var showPreview = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .sheet(item: $pendingDeleteID) { pending in
            DeleteConfirmationSheet(
                torrentName: manager.torrents.first(where: { $0.id == pending.id })?.name ?? "",
                deleteFiles: $deleteFiles
            ) {
                manager.remove(id: pending.id, deleteData: deleteFiles)
                if selectedID == pending.id { selectedID = nil }
                pendingDeleteID = nil
                deleteFiles = false
            } onCancel: {
                pendingDeleteID = nil
                deleteFiles = false
            }
        }
        .sheet(isPresented: $showMagnetSheet) {
            MagnetLinkSheet(uri: $magnetURI) { uri in
                manager.startMagnetPreview(uri: uri)
                showMagnetSheet = false
                magnetURI = ""
                showPreview = true
            } onCancel: {
                showMagnetSheet = false
                magnetURI = ""
            }
        }
        .sheet(isPresented: $showPreview) {
            TorrentAddSheet(manager: manager) {
                manager.confirmPreviewDownload()
                showPreview = false
            } onCancel: {
                manager.cancelPreview()
                showPreview = false
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.init(filenameExtension: "torrent")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                manager.startTorrentFilePreview(from: url)
                if accessed { url.stopAccessingSecurityScopedResource() }
                showPreview = true
            case .failure(let error):
                manager.errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("OK") { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(manager.torrents, selection: $selectedID) { torrent in
            TorrentRow(manager: manager, torrentID: torrent.id) {
                pendingDeleteID = PendingDelete(id: torrent.id)
            }
            .tag(torrent.id)
        }
        .listStyle(.sidebar)
        .navigationTitle("shade-torrent")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isImporting = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add Torrent File")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showMagnetSheet = true } label: {
                    Image(systemName: "link")
                }
                .help("Add Magnet Link")
            }
        }
        .overlay {
            if manager.torrents.isEmpty {
                ContentUnavailableView(
                    "No Torrents",
                    systemImage: "arrow.down.circle",
                    description: Text("Click + to add a .torrent file.")
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let id = selectedID {
            TorrentDetailView(manager: manager, torrentID: id) {
                pendingDeleteID = PendingDelete(id: id)
            }
        } else {
            ContentUnavailableView("Select a Torrent", systemImage: "arrow.down.circle")
        }
    }
}

// MARK: - TorrentRow

struct TorrentRow: View {
    let manager: TorrentManager
    let torrentID: UUID
    let onRequestDelete: () -> Void

    private var torrent: TorrentItem? {
        manager.torrents.first { $0.id == torrentID }
    }

    var body: some View {
        if let torrent {
            VStack(alignment: .leading, spacing: 4) {
                Text(torrent.name)
                    .font(.headline)
                    .lineLimit(1)

                ProgressView(value: torrent.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(torrent.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if torrent.downloadRate > 0 && !torrent.isPaused {
                        Label(torrent.downloadRate.formattedRate, systemImage: "arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                torrentContextMenu(torrent)
            }
        }
    }

    @ViewBuilder
    private func torrentContextMenu(_ torrent: TorrentItem) -> some View {
        if torrent.isStopped || torrent.isPaused {
            Button("Start") { manager.resume(id: torrentID) }
        } else {
            Button("Pause") { manager.pause(id: torrentID) }
            Button("Stop")  { manager.stop(id: torrentID) }
        }
        if !torrent.savePath.isEmpty {
            Button("Open in Finder") {
                let base = URL(fileURLWithPath: torrent.savePath)
                let named = base.appendingPathComponent(torrent.name)
                if FileManager.default.fileExists(atPath: named.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([named])
                } else {
                    NSWorkspace.shared.open(base)
                }
            }
        }
        Divider()
        Button("Remove…", role: .destructive) { onRequestDelete() }
    }
}

// MARK: - TorrentDetailView

struct TorrentDetailView: View {
    let manager: TorrentManager
    let torrentID: UUID
    let onRequestDelete: () -> Void

    private var torrent: TorrentItem? {
        manager.torrents.first { $0.id == torrentID }
    }

    var body: some View {
        if let torrent {
            List {
                Section("Download") {
                    LabeledContent("Status", value: torrent.statusLabel)
                    LabeledContent("Progress", value: String(format: "%.1f%%", torrent.progress * 100))
                    ProgressView(value: torrent.progress)
                        .listRowSeparator(.hidden)
                    LabeledContent("Downloaded", value: torrent.totalDone.formattedSize)
                    if torrent.downloadRate > 0 {
                        LabeledContent("↓ Speed", value: torrent.downloadRate.formattedRate)
                    }
                    if torrent.uploadRate > 0 {
                        LabeledContent("↑ Speed", value: torrent.uploadRate.formattedRate)
                    }
                    LabeledContent("Seeds", value: "\(torrent.numSeeds) connected (\(torrent.listSeeds) in swarm)")
                    LabeledContent("Peers", value: "\(torrent.numPeers) connected (\(torrent.listPeers) in swarm)")
                }

                Section("Info") {
                    LabeledContent("Name", value: torrent.name)
                    LabeledContent("Total Size", value: torrent.totalSize.formattedSize)
                    LabeledContent("Files", value: "\(torrent.files.count)")
                    if !torrent.savePath.isEmpty {
                        LabeledContent("Location", value: torrent.savePath)
                    }
                }

                Section("Files") {
                    ForEach(Array(torrent.files.enumerated()), id: \.element.id) { idx, file in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { file.isSelected },
                                    set: { _ in manager.toggleFile(torrentID: torrentID, fileIndex: idx) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                Image(systemName: "doc")
                                    .foregroundStyle(file.isSelected ? .primary : .secondary)
                                Text(file.name)
                                    .lineLimit(1)
                                    .foregroundStyle(file.isSelected ? .primary : .secondary)
                                Spacer()
                                if file.isSelected {
                                    Text(String(format: "%.1f%%", file.progress * 100))
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                        .frame(width: 42, alignment: .trailing)
                                }
                                Text(file.size.formattedSize)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .frame(width: 60, alignment: .trailing)
                            }
                            if file.isSelected {
                                ProgressView(value: Double(file.progress))
                                    .progressViewStyle(.linear)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(torrent.name)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if torrent.isStopped || torrent.isPaused {
                        Button { manager.resume(id: torrentID) } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("Start")
                    } else {
                        Button { manager.pause(id: torrentID) } label: {
                            Image(systemName: "pause.fill")
                        }
                        .disabled(torrent.state == .finished || torrent.state == .seeding)
                        .help("Pause")

                        Button { manager.stop(id: torrentID) } label: {
                            Image(systemName: "stop.fill")
                        }
                        .help("Stop")
                    }

                    Button(role: .destructive) { onRequestDelete() } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove torrent…")
                }
            }
        }
    }
}

// MARK: - MagnetLinkSheet

struct MagnetLinkSheet: View {
    @Binding var uri: String
    let onAdd: (String) -> Void
    let onCancel: () -> Void

    private var isValid: Bool { uri.hasPrefix("magnet:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Magnet Link")
                .font(.headline)

            TextField("magnet:?xt=urn:btih:…", text: $uri)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Add") { onAdd(uri) }
                    .disabled(!isValid)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Supporting types

struct PendingDelete: Identifiable {
    let id: UUID
}

// MARK: - DeleteConfirmationSheet

struct DeleteConfirmationSheet: View {
    let torrentName: String
    @Binding var deleteFiles: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remove Torrent")
                    .font(.headline)
                Text("Are you sure you want to remove \"\(torrentName)\"?")
                    .foregroundStyle(.secondary)
            }

            Toggle("Also delete downloaded files", isOn: $deleteFiles)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Remove", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - TorrentAddSheet

struct TorrentAddSheet: View {
    let manager: TorrentManager
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Torrent")
                .font(.headline)
                .padding(.bottom, 16)

            if let info = manager.previewInfo {
                // Info rows
                LabeledContent("Name", value: info.name)
                LabeledContent("Size", value: Int64(info.totalSize).formattedSize)
                LabeledContent("Files", value: "\(info.files.count)")

                // Save location
                HStack {
                    Text("Save to")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(URL(fileURLWithPath: manager.previewSavePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select"
                        if panel.runModal() == .OK, let url = panel.url {
                            manager.previewSavePath = url.path
                            manager.previewScopedURL = url
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 8)

                Divider()
                    .padding(.vertical, 12)

                // Select all toggle header
                let allSelected = manager.previewSelectedFiles.count == info.files.count
                Toggle(isOn: Binding(
                    get: { allSelected },
                    set: { on in
                        manager.previewSelectedFiles = on ? Set(0..<info.files.count) : []
                    }
                )) {
                    Text("Files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(info.files.enumerated()), id: \.offset) { idx, file in
                            Toggle(isOn: Binding(
                                get: { manager.previewSelectedFiles.contains(idx) },
                                set: { on in
                                    if on { manager.previewSelectedFiles.insert(idx) }
                                    else  { manager.previewSelectedFiles.remove(idx) }
                                }
                            )) {
                                HStack {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(file.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Int64(file.size).formattedSize)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching metadata…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Divider()
                .padding(.top, 12)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Download", action: onDownload)
                    .disabled(manager.previewInfo == nil || manager.previewSelectedFiles.isEmpty)
                    .keyboardShortcut(.return)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 500)
    }
}

extension TorrentItem: Hashable {
    static func == (lhs: TorrentItem, rhs: TorrentItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    ContentView()
}
