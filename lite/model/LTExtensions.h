#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const LTExtensionsChanged;
/// Chromium's extension ID for a SubjectPublicKeyInfo DER key or an unpacked directory.
FOUNDATION_EXPORT NSString *LTExtensionIDForKey(NSData *publicKey);
FOUNDATION_EXPORT NSString *LTExtensionIDForPath(NSString *realPath);
FOUNDATION_EXPORT BOOL LTValidExtensionID(NSString *_Nullable identifier);
/// Accepts a bare ID or a chromewebstore.google.com / chrome.google.com/webstore detail URL.
FOUNDATION_EXPORT NSString *_Nullable LTWebStoreExtensionID(NSString *text);
FOUNDATION_EXPORT NSURL *LTWebStoreDownloadURL(NSString *identifier);
FOUNDATION_EXPORT NSData *LTWebStorePublisherKeyHash(void);
/// Verifies every signature of a CRX3 package and returns its ZIP archive. The
/// developer key must match the signed CRX ID (and |expectedID| when given). When
/// |requiredKeyHash| is given, a key with that SHA-256 must also have signed it.
FOUNDATION_EXPORT NSData *_Nullable LTVerifyCRX(NSData *crx, NSString *_Nullable expectedID,
                                                NSData *_Nullable requiredKeyHash,
                                                NSData *_Nullable *_Nullable developerKey,
                                                NSError **error);

@interface LTExtension : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSString *source; // "unpacked" or "webstore"
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *version;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly, nullable) NSString *popup;
@property (nonatomic, readonly, nullable) NSString *options;
@property (nonatomic, readonly, nullable) NSString *iconPath;
/// Chrome-style summaries of what the extension can access.
@property (nonatomic, readonly) NSArray<NSString *> *warnings;
/// Set when the files can no longer be loaded; such an extension is never passed to Chromium.
@property (nonatomic, readonly, nullable) NSString *problem;
- (nullable NSString *)URLForPage:(nullable NSString *)page;
@end

/// Profile-scoped list of extensions Lite passes to Chromium at launch. Chromium
/// reads the list once, so changes take effect after a restart.
@interface LTExtensions : NSObject
@property (nonatomic, readonly) NSString *directory;
@property (nonatomic, readonly) NSArray<LTExtension *> *extensions;
/// Extensions that were enabled and valid when Chromium started.
@property (nonatomic, readonly) NSArray<LTExtension *> *launched;
@property (nonatomic, readonly) BOOL restartRequired;
- (instancetype)initWithProfilePath:(NSString *)profile;
/// Comma-separated directories for Chromium's --load-extension switch. Records the launched set.
- (NSString *)launchSwitch;
- (nullable LTExtension *)extensionWithIdentifier:(NSString *)identifier;
- (nullable LTExtension *)addUnpackedAtPath:(NSString *)path error:(NSError **)error;
- (nullable LTExtension *)installPackage:(NSData *)crx
                              identifier:(NSString *)identifier
                         requiredKeyHash:(nullable NSData *)requiredKeyHash
                                   error:(NSError **)error;
- (void)installFromWebStore:(NSString *)identifier
                 completion:(void (^)(LTExtension *_Nullable extension, NSError *_Nullable error))completion;
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
