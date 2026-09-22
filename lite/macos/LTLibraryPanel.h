#import "../model/LTStore.h"
#import <Cocoa/Cocoa.h>
@interface LTLibraryPanel : NSWindowController
@property (nonatomic, copy) void (^openURL)(NSString *);
@property (nonatomic, copy) void (^command)(NSString *);
@property (nonatomic, copy) void (^downloadAction)(NSDictionary *, NSString *);
- (instancetype)initWithStore:(LTStore *)store;
- (void)showMode:(NSString *)mode owner:(NSWindow *)owner downloads:(NSArray *)downloads;
- (void)updateDownloads:(NSArray *)downloads;
@end
