#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Crashpad stores minidumps in the profile's Chromium directory. Nothing leaves this
// Mac unless the user approves those exact reports through sendReports:completion:.
FOUNDATION_EXPORT NSURL *_Nullable LTCrashUploadURL(NSString *_Nullable value);
@interface LTCrashReports : NSObject
@property (nonatomic, readonly) BOOL canUpload;
// Reports from before this launch that are eligible to be offered.
@property (nonatomic, readonly) NSArray<NSString *> *reports;
// Extra multipart fields sent with each report.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *uploadFields;
- (instancetype)initWithProfilePath:(NSString *)path uploadURL:(nullable NSURL *)url;
- (instancetype)initWithProfilePath:(NSString *)path uploadURL:(nullable NSURL *)url
                      configuration:(NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Run before the engine starts. Deletes dumps from runs that had a private window
// and dumps past the retention period, then lists what remains.
- (void)prepareForLaunch;
// Call before creating a private window. Reports after this point are never offered.
- (void)notePrivateSession;
- (void)discardReports:(NSArray<NSString *> *)reports;
// A sent report is deleted. A failed report stays, to be offered again next launch.
- (void)sendReports:(NSArray<NSString *> *)reports
         completion:(void (^)(NSUInteger sent, NSUInteger failed))completion;
@end
NS_ASSUME_NONNULL_END
