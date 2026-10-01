#import <Foundation/Foundation.h>
@class LTPage;
extern NSNotificationName const LTDownloadHistoryChanged;
@interface LTDownloadHistory : NSObject
@property (nonatomic, readonly) NSArray<NSDictionary *> *rows;
@property (nonatomic, readonly) NSString *saveError;
- (instancetype)initWithPath:(NSString *)path contextIdentifier:(NSString *)contextIdentifier;
- (void)performAction:(NSString *)action download:(NSDictionary *)download;
- (void)flush;
@end
