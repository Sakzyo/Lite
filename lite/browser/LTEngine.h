#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@class LTPage;
@protocol LTPageDelegate <NSObject>
- (void)pageChanged:(LTPage *)page;
- (void)pageClosed:(LTPage *)page;
- (void)pageCloseCanceled:(LTPage *)page;
- (void)page:(LTPage *)page openURL:(NSString *)url;
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download;
@optional
- (void)page:(LTPage *)page submittedLogin:(NSDictionary *)login;
@end
@interface LTBrowserContext : NSObject
@property (nonatomic, readonly) NSString *contextIdentifier;
- (instancetype)initPrivate:(BOOL)privateMode;
- (void)updateBlockingPreferences:(nullable NSDictionary *)preferences;
- (void)clearData;
- (void)clearCookiesAndCacheWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (BOOL)configureFixtureProxyForTesting;
- (void)closeAllBrowsersConfirmed;
@end
@interface LTPage : NSObject
@property (nonatomic, weak) id<LTPageDelegate> delegate;
@property (nonatomic, readonly) NSView *container;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic, nullable) NSImage *favicon;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL canBack;
@property (nonatomic) BOOL canForward;
@property (nonatomic) BOOL secure;
@property (nonatomic) BOOL audible;
@property (nonatomic) BOOL capturing;
@property (nonatomic) BOOL dirty;
@property (nonatomic) BOOL downloading;
@property (nonatomic) BOOL frozen;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL keepAwake;
@property (nonatomic) BOOL pictureInPicture;
@property (nonatomic) double lastVisible;
@property (nonatomic, readonly) BOOL alive;
@property (nonatomic, readonly) NSUInteger blockedRequests;
@property (nonatomic, readonly) BOOL privateMode;
@property (nonatomic, readonly) NSString *contextIdentifier;
@property (nonatomic, readonly) NSArray<NSDictionary *> *permissionGrants;
@property (nonatomic, copy, nullable) NSDictionary *sessionState;
- (void)revokePermissions;
- (void)clearSiteDataWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)captureSessionState:(void (^)(void))completion;
- (instancetype)initWithID:(NSString *)identifier
                       url:(NSString *)url
                   context:(nullable LTBrowserContext *)context;
- (void)loadIfNeeded;
- (void)navigate:(NSString *)url;
- (void)back;
- (void)forward;
- (void)reload;
- (void)stop;
- (void)focus;
- (void)close;
- (void)closeConfirmed;
- (void)discard;
- (void)freeze:(BOOL)freeze;
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding;
- (void)zoom:(double)delta;
- (void)resetZoom;
- (void)print;
- (void)save;
- (void)showDevTools;
- (BOOL)hasDevTools;
- (void)closeDevTools;
- (void)toggleMute;
- (void)togglePlayback;
- (void)enterPictureInPicture;
- (void)downloadAction:(NSString *)action identifier:(NSInteger)identifier;
- (void)evaluateForTesting:(NSString *)expression
                completion:(void (^)(id _Nullable value, BOOL success))completion;
- (void)evaluateJavaScript:(NSString *)expression
                completion:(void (^)(id _Nullable value, BOOL success))completion;
@end
NSUInteger LTLivingBrowserCount(void);
void LTCloseAllBrowsers(void);
void LTCloseAllBrowsersConfirmed(void);
void LTQuitWhenBrowsersClose(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTBrowserTasks(void);
FOUNDATION_EXPORT BOOL LTEndBrowserTask(NSNumber *identifier);
FOUNDATION_EXPORT void LTStopBrowserTaskMonitoring(void);
NS_ASSUME_NONNULL_END
