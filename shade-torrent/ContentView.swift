//
//  ContentView.swift
//  shade-torrent
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var manager = TorrentManager()
    @State private var isImporting = false
    @State private var selectedID: UUID?
    @State private var pendingDeleteID: PendingDelete?
    @State private var deleteFiles = false
    @State private var showMagnetSheet = false
    @State private var magnetURI = ""
    @State private var showMagnetPreview = false

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
                showMagnetPreview = true
            } onCancel: {
                showMagnetSheet = false
                magnetURI = ""
            }
        }
        .sheet(isPresented: $showMagnetPreview) {
            MagnetPreviewSheet(manager: manager) {
                manager.confirmPreviewDownload()
                showMagnetPreview = false
            } onCancel: {
                manager.cancelPreview()
                showMagnetPreview = false
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
                manager.addTorrent(from: url)
                if accessed { url.stopAccessingSecurityScopedResource() }
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
                }

                Section("Files") {
                    ForEach(torrent.files) { file in
                        HStack {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            Text(file.name)
                                .lineLimit(1)
                            Spacer()
                            Text(file.size.formattedSize)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
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

// MARK: - MagnetPreviewSheet

struct MagnetPreviewSheet: View {
    let manager: TorrentManager
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Add Torrent")
                .font(.headline)
                .padding(.bottom, 16)

            if let info = manager.previewInfo {
                // Metadata ready
                Group {
                    LabeledContent("Name", value: info.name)
                    LabeledContent("Size", value: Int64(info.totalSize).formattedSize)
                    LabeledContent("Files", value: "\(info.files.count)")
                }
                .padding(.bottom, 8)

                Divider()
                    .padding(.vertical, 8)

                Text("Files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(info.files, id: \.name) { file in
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
                    }
                }
                .frame(maxHeight: 200)
            } else {
                // Still loading
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
                Button("Download") { onDownload() }
                    .disabled(manager.previewInfo == nil)
                    .keyboardShortcut(.return)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 480)
    }
}

extension TorrentItem: Hashable {
    static func == (lhs: TorrentItem, rhs: TorrentItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    ContentView()
}
