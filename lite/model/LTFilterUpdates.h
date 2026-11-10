#import "../browser/LTContentBlocker.h"
#import <Security/Security.h>
NS_ASSUME_NONNULL_BEGIN

// Signed content-blocking filter updates. A feed is a directory on a web server holding
// `filters.json`, a manifest; `filters.json.sig`, a base64 P-256 ECDSA SHA-256 signature of the
// manifest's exact bytes; and `<serial>/<file>` for each file the manifest lists. The manifest names
// every file with its size and SHA-256, so the signature covers all of them.
//
// {"format": "lite-filters", "version": 1, "serial": 202611101200, "created": "...",
//  "files": {"network.json": {"sha256": "…", "size": 4715772}, …}}

FOUNDATION_EXPORT NSString *const LTFilterFormat;
// Posted on the main queue when a check started by -updateFilters finishes.
FOUNDATION_EXPORT NSNotificationName const LTFilterUpdatesChanged;
// The manifest version this build reads. A newer one is refused until Lite is updated.
FOUNDATION_EXPORT const NSInteger LTFilterFormatVersion;
// The files an update replaces. A manifest must list exactly these.
FOUNDATION_EXPORT NSArray<NSString *> *LTFilterFiles(void);
// The `serial` in a filter directory's provenance.json, or 0 when it has none.
FOUNDATION_EXPORT int64_t LTFilterSerial(NSString *directory);
// "10 November 2026" for a serial, or nil when it is not a date.
FOUNDATION_EXPORT NSString *_Nullable LTFilterSerialDate(int64_t serial);
// A feed address Lite will use: https, or http on this Mac only, with a host and no user name.
FOUNDATION_EXPORT NSURL *_Nullable LTFilterFeedURL(NSString *_Nullable text);
// A P-256 public key from base64 of its 65-byte uncompressed point or its SubjectPublicKeyInfo DER.
FOUNDATION_EXPORT SecKeyRef _Nullable LTFilterPublicKeyCreate(NSString *_Nullable base64) CF_RETURNS_RETAINED;
// The manifest's fields when `signature` is `key`'s signature of `manifest` and every field is
// well formed; otherwise nil and an error.
FOUNDATION_EXPORT NSDictionary *_Nullable LTVerifiedFilterManifest(NSData *manifest, NSData *signature,
                                                                   SecKeyRef key, NSError **error);

@interface LTFilterUpdater : NSObject
// The updater the app created from its configuration, or nil when the build has no feed.
@property (class, nonatomic, nullable) LTFilterUpdater *shared;
@property (nonatomic, readonly) NSURL *feed;
@property (nonatomic, readonly) NSString *directory;
// When the last check finished (seconds since 1970, 0 if never) and what it found, for display.
// Both are saved in the directory, so they survive relaunching.
@property (nonatomic, readonly) double lastCheck;
@property (nonatomic, readonly, copy) NSString *lastResult;
@property (nonatomic, readonly) BOOL checking;
// How long after a failed check the next one is due, and how long a request may wait for data.
// One hour and 30 seconds unless changed, for tests.
@property (nonatomic) double retryInterval;
@property (nonatomic) double requestTimeout;
// Extra NSURLProtocol classes, for tests.
@property (nonatomic, copy, nullable) NSArray<Class> *protocolClasses;
// nil unless the feed passes LTFilterFeedURL and the key LTFilterPublicKeyCreate. `directory` is
// created with owner-only permissions.
- (nullable instancetype)initWithFeed:(NSString *)feed publicKey:(NSString *)key directory:(NSString *)directory;
// The installed set, compiled, when it verifies again and is newer than `serial`, the bundled set's.
// A set that does not verify, does not compile, or is not newer is deleted, so the next check can
// install a good one.
- (nullable LTContentBlocker *)installedBlockerNewerThan:(int64_t)serial;
// Asks the feed for a set newer than `serial`. When there is one and every file matches the signed
// manifest and compiles, it is saved and passed to `completion`, which runs on the main queue.
// `blocker` is nil when nothing is newer or the check failed; `error` says why it failed. Requests
// carry no cookies or cache and do not follow redirects. A second call while one runs fails.
- (void)checkNewerThan:(int64_t)serial
            completion:(void (^)(LTContentBlocker *_Nullable blocker, NSError *_Nullable error))completion;
// Checks for filters newer than the ones in use and installs them with +[LTContentBlocker install:].
// Posts LTFilterUpdatesChanged when finished.
- (void)updateFilters;
// Whether a scheduled check is due: never checked, 24 hours since the last check, or
// `retryInterval` since the last check failed.
- (BOOL)isDue:(double)now;
@end
NS_ASSUME_NONNULL_END
