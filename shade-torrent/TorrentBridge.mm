//
//  TorrentBridge.mm
//  shade-torrent
//

#import "TorrentBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/magnet_uri.hpp>
#pragma clang diagnostic pop

#include <memory>
#include <vector>
#include <stdexcept>

// MARK: - Private C++ session wrapper

struct SessionImpl {
    std::unique_ptr<lt::session> session;
    std::vector<lt::torrent_handle> handles;
    std::vector<lt::torrent_handle> previewHandles;

    SessionImpl() {
        lt::settings_pack pack;
        // Only emit error and status alerts — we poll handles directly for progress
        pack.set_int(lt::settings_pack::alert_mask,
                     static_cast<int>(lt::alert_category::error |
                                      lt::alert_category::status));
        session = std::make_unique<lt::session>(std::move(pack));
    }
};

// MARK: - TorrentFileEntry

@implementation TorrentFileEntry
@end

// MARK: - TorrentFileInfo

@implementation TorrentFileInfo
@end

// MARK: - TorrentStatus

@implementation TorrentStatus
@end

// MARK: - TorrentBridge

@interface TorrentBridge () {
    SessionImpl *_impl;
}
@end

@implementation TorrentBridge

+ (instancetype)shared {
    static TorrentBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TorrentBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _impl = new SessionImpl();
    }
    return self;
}

// MARK: - Parse

- (nullable TorrentFileInfo *)parseTorrentFile:(NSString *)path error:(NSError **)error {
    try {
        lt::torrent_info ti(std::string(path.UTF8String));

        TorrentFileInfo *info = [[TorrentFileInfo alloc] init];
        info.name       = [NSString stringWithUTF8String:ti.name().c_str()];
        info.totalSize  = ti.total_size();
        info.filePath   = path;

        // Store raw bytes so startDownload can reconstruct without re-reading the file
        NSData *data = [NSData dataWithContentsOfFile:path];
        info.torrentData = data;

        const lt::file_storage &fs = ti.files();
        NSMutableArray<TorrentFileEntry *> *files =
            [NSMutableArray arrayWithCapacity:fs.num_files()];
        for (lt::file_index_t i{0}; i < lt::file_index_t{fs.num_files()}; ++i) {
            TorrentFileEntry *entry = [[TorrentFileEntry alloc] init];
            entry.name = [NSString stringWithUTF8String:fs.file_name(i).to_string().c_str()];
            entry.size = fs.file_size(i);
            [files addObject:entry];
        }
        info.files = files;

        return info;
    } catch (lt::system_error const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:e.code().value()
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return nil;
    } catch (std::exception const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return nil;
    }
}

// MARK: - Start Download

- (BOOL)startDownload:(TorrentFileInfo *)torrent savePath:(NSString *)savePath error:(NSError **)error {
    try {
        // Reconstruct torrent_info from the cached raw bytes (no file access needed)
        lt::span<char const> buf{(char const *)torrent.torrentData.bytes,
                                 (std::ptrdiff_t)torrent.torrentData.length};
        lt::error_code dec_ec;
        lt::bdecode_node node = lt::bdecode(buf, dec_ec);
        if (dec_ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:dec_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:dec_ec.message().c_str()]}];
            }
            return NO;
        }

        lt::add_torrent_params params;
        params.ti        = std::make_shared<lt::torrent_info>(node);
        params.save_path = std::string(savePath.UTF8String);

        lt::error_code add_ec;
        lt::torrent_handle h = _impl->session->add_torrent(std::move(params), add_ec);
        if (add_ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:add_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:add_ec.message().c_str()]}];
            }
            return NO;
        }

        _impl->handles.push_back(h);
        return YES;
    } catch (std::exception const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return NO;
    }
}

// MARK: - Poll Statuses

- (NSArray<TorrentStatus *> *)pollStatuses {
    NSMutableArray<TorrentStatus *> *result =
        [NSMutableArray arrayWithCapacity:_impl->handles.size()];

    for (auto &h : _impl->handles) {
        TorrentStatus *s = [[TorrentStatus alloc] init];

        if (!h.is_valid()) {
            s.state = TorrentDownloadStateError;
            s.errorMessage = @"Invalid handle";
            [result addObject:s];
            continue;
        }

        lt::torrent_status st;
        try {
            st = h.status();
        } catch (...) {
            s.state = TorrentDownloadStateError;
            s.errorMessage = @"Failed to get status";
            [result addObject:s];
            continue;
        }

        s.progress     = st.progress;
        s.downloadRate = st.download_rate;
        s.uploadRate   = st.upload_rate;
        s.totalDone    = st.total_done;
        s.paused       = (bool)(st.flags & lt::torrent_flags::paused);
        s.numSeeds     = st.num_seeds;
        s.numPeers     = st.num_peers;
        s.listSeeds    = st.list_seeds;
        s.listPeers    = st.list_peers;

        if (st.errc) {
            s.state        = TorrentDownloadStateError;
            s.errorMessage = [NSString stringWithUTF8String:st.errc.message().c_str()];
        } else {
            switch (st.state) {
                case lt::torrent_status::checking_files:
                case lt::torrent_status::checking_resume_data:
                    s.state = TorrentDownloadStateChecking; break;
                case lt::torrent_status::downloading_metadata:
                    s.state = TorrentDownloadStateQueued; break;
                case lt::torrent_status::downloading:
                    s.state = TorrentDownloadStateDownloading; break;
                case lt::torrent_status::finished:
                    s.state = TorrentDownloadStateFinished; break;
                case lt::torrent_status::seeding:
                    s.state = TorrentDownloadStateSeeding; break;
                default:
                    s.state = TorrentDownloadStateQueued; break;
            }
        }

        // Populate resolved metadata once it's available (magnet links start without it)
        try {
            auto tf = h.torrent_file();
            if (tf) {
                s.metadataReady = YES;
                s.resolvedName = [NSString stringWithUTF8String:tf->name().c_str()];
                s.resolvedTotalSize = tf->total_size();
                const lt::file_storage &fs = tf->files();
                NSMutableArray<TorrentFileEntry *> *entries =
                    [NSMutableArray arrayWithCapacity:fs.num_files()];
                for (lt::file_index_t fi{0}; fi < lt::file_index_t{fs.num_files()}; ++fi) {
                    TorrentFileEntry *e = [[TorrentFileEntry alloc] init];
                    e.name = [NSString stringWithUTF8String:fs.file_name(fi).to_string().c_str()];
                    e.size = fs.file_size(fi);
                    [entries addObject:e];
                }
                s.resolvedFiles = entries;
            }
        } catch (...) {}

        [result addObject:s];
    }

    return result;
}

// MARK: - Magnet Links

- (nullable TorrentFileInfo *)addMagnetLink:(NSString *)uri savePath:(NSString *)savePath error:(NSError **)error {
    try {
        lt::error_code parse_ec;
        lt::add_torrent_params params = lt::parse_magnet_uri(std::string(uri.UTF8String), parse_ec);
        if (parse_ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:parse_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:parse_ec.message().c_str()]}];
            }
            return nil;
        }

        // Capture name before moving params into add_torrent
        NSString *displayName = params.name.empty()
            ? @"Loading metadata…"
            : [NSString stringWithUTF8String:params.name.c_str()];

        params.save_path = std::string(savePath.UTF8String);

        lt::error_code add_ec;
        lt::torrent_handle h = _impl->session->add_torrent(std::move(params), add_ec);
        if (add_ec || !h.is_valid()) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:add_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:add_ec.message().c_str()]}];
            }
            return nil;
        }

        _impl->handles.push_back(h);

        TorrentFileInfo *info = [[TorrentFileInfo alloc] init];
        info.name       = displayName;
        info.totalSize  = 0;
        info.files      = @[];
        info.filePath   = uri;
        info.torrentData = nil;
        return info;
    } catch (std::exception const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return nil;
    }
}

// MARK: - Magnet Preview

- (NSInteger)addMagnetForPreview:(NSString *)uri savePath:(NSString *)savePath error:(NSError **)error {
    try {
        lt::error_code parse_ec;
        lt::add_torrent_params params = lt::parse_magnet_uri(std::string(uri.UTF8String), parse_ec);
        if (parse_ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:parse_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:parse_ec.message().c_str()]}];
            }
            return -1;
        }

        params.save_path = std::string(savePath.UTF8String);
        // Leave flags at default (auto_managed ON) so DHT/peers are actively contacted.
        // pollPreviewMetadata will unset auto_managed and pause once metadata arrives.

        lt::error_code add_ec;
        lt::torrent_handle h = _impl->session->add_torrent(std::move(params), add_ec);
        if (add_ec || !h.is_valid()) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:add_ec.value()
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        [NSString stringWithUTF8String:add_ec.message().c_str()]}];
            }
            return -1;
        }

        _impl->previewHandles.push_back(h);
        return (NSInteger)(_impl->previewHandles.size() - 1);
    } catch (std::exception const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return -1;
    }
}

- (nullable TorrentFileInfo *)pollPreviewMetadata:(NSInteger)previewIndex {
    if (previewIndex < 0 || previewIndex >= (NSInteger)_impl->previewHandles.size()) return nil;
    try {
        auto &h = _impl->previewHandles[previewIndex];
        if (!h.is_valid()) return nil;

        auto tf = h.torrent_file();
        if (!tf) return nil;

        // Metadata just arrived — take manual control before the scheduler starts downloading
        h.unset_flags(lt::torrent_flags::auto_managed);
        h.pause(lt::torrent_handle::graceful_pause);

        TorrentFileInfo *info = [[TorrentFileInfo alloc] init];
        info.name      = [NSString stringWithUTF8String:tf->name().c_str()];
        info.totalSize = tf->total_size();
        info.filePath  = @"";

        const lt::file_storage &fs = tf->files();
        NSMutableArray<TorrentFileEntry *> *files =
            [NSMutableArray arrayWithCapacity:fs.num_files()];
        for (lt::file_index_t i{0}; i < lt::file_index_t{fs.num_files()}; ++i) {
            TorrentFileEntry *entry = [[TorrentFileEntry alloc] init];
            entry.name = [NSString stringWithUTF8String:fs.file_name(i).to_string().c_str()];
            entry.size = fs.file_size(i);
            [files addObject:entry];
        }
        info.files = files;
        return info;
    } catch (...) {
        return nil;
    }
}

- (BOOL)startPreviewDownload:(NSInteger)previewIndex error:(NSError **)error {
    if (previewIndex < 0 || previewIndex >= (NSInteger)_impl->previewHandles.size()) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid preview index"}];
        }
        return NO;
    }
    try {
        auto h = _impl->previewHandles[previewIndex];
        if (!h.is_valid()) {
            if (error) {
                *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid handle"}];
            }
            return NO;
        }
        // Promote: enable auto-management and resume
        h.set_flags(lt::torrent_flags::auto_managed);
        h.resume();
        _impl->handles.push_back(h);
        _impl->previewHandles.erase(_impl->previewHandles.begin() + previewIndex);
        return YES;
    } catch (std::exception const &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TorrentBridgeError"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:e.what()]}];
        }
        return NO;
    }
}

- (void)cancelPreview:(NSInteger)previewIndex {
    if (previewIndex < 0 || previewIndex >= (NSInteger)_impl->previewHandles.size()) return;
    try {
        _impl->session->remove_torrent(_impl->previewHandles[previewIndex]);
        _impl->previewHandles.erase(_impl->previewHandles.begin() + previewIndex);
    } catch (...) {}
}

// MARK: - Pause / Resume / Stop

- (void)pauseTorrentAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_impl->handles.size()) return;
    try {
        auto &h = _impl->handles[index];
        // Disable auto-management so the session scheduler can't override the pause
        h.unset_flags(lt::torrent_flags::auto_managed);
        h.pause(lt::torrent_handle::graceful_pause);
    } catch (...) {}
}

- (void)resumeTorrentAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_impl->handles.size()) return;
    try {
        auto &h = _impl->handles[index];
        h.set_flags(lt::torrent_flags::auto_managed);
        h.resume();
    } catch (...) {}
}

- (void)stopTorrentAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_impl->handles.size()) return;
    try {
        auto &h = _impl->handles[index];
        h.unset_flags(lt::torrent_flags::auto_managed);
        h.pause(); // immediate — no graceful_pause, kills connections now
    } catch (...) {}
}

- (void)removeTorrentAtIndex:(NSInteger)index deleteData:(BOOL)deleteData {
    if (index < 0 || index >= (NSInteger)_impl->handles.size()) return;
    try {
        auto flags = deleteData
            ? lt::session_handle::delete_files
            : lt::remove_flags_t{};
        _impl->session->remove_torrent(_impl->handles[index], flags);
        _impl->handles.erase(_impl->handles.begin() + index);
    } catch (...) {}
}

@end
