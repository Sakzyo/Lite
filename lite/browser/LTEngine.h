#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@class LTPage;
@protocol LTPageDelegate <NSObject>
- (void)pageChanged:(LTPage *)page;
- (void)pageClosed:(LTPage *)page;
- (void)pageCloseCanceled:(LTPage *)page;
- (void)page:(LTPage *)page openURL:(NSString *)url;
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download;
@end
@interface LTBrowserContext : NSObject
- (instancetype)initPrivate:(BOOL)privateMode;
- (void)updateBlockingPreferences:(nullable NSDictionary *)preferences;
- (void)clearData;
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
void LTQuitWhenBrowsersClose(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTBrowserTasks(void);
FOUNDATION_EXPORT BOOL LTEndBrowserTask(NSNumber *identifier);
FOUNDATION_EXPORT void LTStopBrowserTaskMonitoring(void);
NS_ASSUME_NONNULL_END
