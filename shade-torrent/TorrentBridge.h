//
//  TorrentBridge.h
//  shade-torrent
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - TorrentDownloadState

typedef NS_ENUM(NSInteger, TorrentDownloadState) {
    TorrentDownloadStateQueued,
    TorrentDownloadStateChecking,
    TorrentDownloadStateDownloading,
    TorrentDownloadStateFinished,
    TorrentDownloadStateSeeding,
    TorrentDownloadStateError,
};

// MARK: - TorrentFileEntry

@interface TorrentFileEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int64_t size;
@end

// MARK: - TorrentFileInfo

@interface TorrentFileInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int64_t totalSize;
@property (nonatomic, strong) NSArray<TorrentFileEntry *> *files;
@property (nonatomic, copy) NSString *filePath;
/// Raw .torrent file bytes — used to start the download without re-reading the file.
@property (nonatomic, strong, nullable) NSData *torrentData;
@end

// MARK: - TorrentStatus

@interface TorrentStatus : NSObject
@property (nonatomic, assign) float progress;       // 0.0 – 1.0
@property (nonatomic, assign) int downloadRate;     // bytes/sec
@property (nonatomic, assign) int uploadRate;       // bytes/sec
@property (nonatomic, assign) int64_t totalDone;    // bytes received
@property (nonatomic, assign) TorrentDownloadState state;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) int numSeeds;      // connected seeds
@property (nonatomic, assign) int numPeers;      // connected peers
@property (nonatomic, assign) int listSeeds;     // seeds in swarm (from tracker)
@property (nonatomic, assign) int listPeers;     // peers in swarm (from tracker)
@property (nonatomic, copy, nullable) NSString *errorMessage;
/// Set once metadata arrives (magnet links start without it)
@property (nonatomic, assign) BOOL metadataReady;
@property (nonatomic, copy, nullable) NSString *resolvedName;
@property (nonatomic, assign) int64_t resolvedTotalSize;
@property (nonatomic, strong, nullable) NSArray<TorrentFileEntry *> *resolvedFiles;
@end

// MARK: - TorrentBridge

@interface TorrentBridge : NSObject

+ (instancetype)shared;

/// Parse a .torrent file and return its metadata. Throws on error.
- (nullable TorrentFileInfo *)parseTorrentFile:(NSString *)path error:(NSError **)error;

/// Add a parsed torrent to the session and begin downloading to savePath. Throws on error.
- (BOOL)startDownload:(TorrentFileInfo *)torrent savePath:(NSString *)savePath error:(NSError **)error;

/// Returns one TorrentStatus per torrent, in the order they were added.
- (NSArray<TorrentStatus *> *)pollStatuses;

/// Add a magnet link and begin downloading to savePath. Returns partial info (name may update later). Throws on error.
- (nullable TorrentFileInfo *)addMagnetLink:(NSString *)uri savePath:(NSString *)savePath error:(NSError **)error;

// MARK: - Magnet preview (two-phase flow)

/// Stage a magnet link paused for metadata fetching. Returns a preview handle index, or -1 on error.
- (NSInteger)addMagnetForPreview:(NSString *)uri savePath:(NSString *)savePath error:(NSError **)error;

/// Poll for resolved metadata on a preview handle. Returns TorrentFileInfo once metadata arrives, nil while still loading.
- (nullable TorrentFileInfo *)pollPreviewMetadata:(NSInteger)previewIndex;

/// Promote a preview handle to an active download. Returns NO on error.
- (BOOL)startPreviewDownload:(NSInteger)previewIndex error:(NSError **)error;

/// Cancel and remove a preview handle from the session.
- (void)cancelPreview:(NSInteger)previewIndex;

- (void)pauseTorrentAtIndex:(NSInteger)index;
- (void)resumeTorrentAtIndex:(NSInteger)index;
- (void)stopTorrentAtIndex:(NSInteger)index;
/// Removes the torrent from the session. Pass deleteData:YES to also erase files on disk.
- (void)removeTorrentAtIndex:(NSInteger)index deleteData:(BOOL)deleteData;

@end

NS_ASSUME_NONNULL_END
