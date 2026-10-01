#import "LTDownloadHistory.h"
#import "../browser/LTEngine.h"
#include <sys/stat.h>
NSNotificationName const LTDownloadHistoryChanged = @"LTDownloadHistoryChanged";
@implementation LTDownloadHistory {
    NSString *_path, *_contextIdentifier, *_runID;
    NSMutableDictionary<NSString *, NSDictionary *> *_records;
    NSMutableDictionary<NSString *, LTPage *> *_owners;
    NSTimer *_saveTimer;
}
- (instancetype)initWithPath:(NSString *)path contextIdentifier:(NSString *)contextIdentifier {
    if ((self = [super init])) {
        _path = [path copy];
        _runID = NSUUID.UUID.UUIDString;
        _contextIdentifier = [contextIdentifier copy];
        _records = [NSMutableDictionary new];
        _owners = [NSMutableDictionary new];
        NSDictionary *attributes = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
        BOOL boundedFile = [attributes[NSFileType] isEqual:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] <= 1024 * 1024;
        NSData *data = boundedFile ? [NSData dataWithContentsOfFile:path] : nil;
        id rows = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([rows isKindOfClass:NSArray.class]) {
            for (id value in rows) {
                if (![value isKindOfClass:NSDictionary.class]) {
                    _saveError = @"The saved download list contains invalid records. Its original file was preserved.";
                    _path = nil;
                    continue;
                }
                BOOL valid = YES;
                for (NSString *field in @[@"key", @"name", @"path", @"url"])
                    valid &= [value[field] isKindOfClass:NSString.class];
                for (NSString *field in @[@"id", @"time", @"active", @"complete", @"canceled", @"paused", @"percent"])
                    valid &= [value[field] isKindOfClass:NSNumber.class];
                for (NSString *field in @[@"reason", @"status", @"securityError"])
                    if (value[field]) valid &= [value[field] isKindOfClass:NSString.class];
                for (NSString *field in @[@"interrupted", @"canResume", @"received", @"total", @"quarantined", @"reasonCode"])
                    if (value[field]) valid &= [value[field] isKindOfClass:NSNumber.class];
                if (!valid) {
                    _saveError = @"The saved download list contains invalid records. The original was preserved; new download history will not overwrite it.";
                    _path = nil;
                    continue;
                }
                if (_records.count >= 200) continue;
                NSMutableDictionary *row = [value mutableCopy];
                if ([row[@"active"] boolValue]) {
                    row[@"active"] = @NO;
                    row[@"paused"] = @NO;
                    row[@"interrupted"] = @YES;
                    row[@"reason"] = @"The previous browser session ended. Download again from the original website.";
                }
                row[@"canResume"] = @NO;
                _records[row[@"key"]] = row;
            }
        } else if (attributes) {
            _saveError = @"The saved download list is unreadable. It was preserved; new download history will not overwrite it.";
            _path = nil;
        }
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(downloadChanged:)
            name:@"LTDownloadChanged" object:nil];
    }
    return self;
}
- (NSArray<NSDictionary *> *)rows {
    return [_records.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"time"] compare:a[@"time"]];
    }];
}
- (void)downloadChanged:(NSNotification *)note {
    LTPage *page = note.object;
    if (![page isKindOfClass:LTPage.class]) return;
    if (_contextIdentifier ? ![page.contextIdentifier isEqual:_contextIdentifier] : page.privateMode) return;
    NSMutableDictionary *row = [note.userInfo mutableCopy];
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@", _runID, page.contextIdentifier, row[@"id"]];
    row[@"key"] = key;
    row[@"time"] = _records[key][@"time"] ?: @(NSDate.date.timeIntervalSince1970);
    _records[key] = row;
    if ([row[@"active"] boolValue] || [row[@"canResume"] boolValue]) _owners[key] = page;
    else [_owners removeObjectForKey:key];
    NSUInteger completed = 0;
    for (NSDictionary *entry in self.rows) {
        if (![entry[@"active"] boolValue] && ++completed > 200) {
            [_records removeObjectForKey:entry[@"key"]];
            [_owners removeObjectForKey:entry[@"key"]];
        }
    }
    if (_path && !_saveTimer) {
        __weak typeof(self) weak = self;
        _saveTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:NO block:^(NSTimer *timer) { [weak flush]; }];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:LTDownloadHistoryChanged object:self];
}
- (void)performAction:(NSString *)action download:(NSDictionary *)download {
    NSString *key = download[@"key"];
    if ([action isEqual:@"forget"] && ![download[@"active"] boolValue]) {
        [_records removeObjectForKey:key];
        [_owners removeObjectForKey:key];
        [self flush];
        [NSNotificationCenter.defaultCenter postNotificationName:LTDownloadHistoryChanged object:self];
    } else [_owners[key] downloadAction:action identifier:[download[@"id"] integerValue]];
}
- (void)flush {
    [_saveTimer invalidate];
    _saveTimer = nil;
    if (!_path) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.rows options:0 error:&error];
    NSString *previousError = _saveError;
    if (data.length > 1024 * 1024) {
        _saveError = @"Download history exceeded its 1 MiB limit. The previous saved list was preserved.";
    } else if (!data || ![data writeToFile:_path options:NSDataWritingAtomic error:&error])
        _saveError = error.localizedDescription ?: @"Could not save the download list.";
    else { chmod(_path.fileSystemRepresentation, 0600); _saveError = nil; }
    if ([_saveError isEqual:previousError] == NO && (_saveError || previousError))
        [NSNotificationCenter.defaultCenter postNotificationName:LTDownloadHistoryChanged object:self];
}
- (void)dealloc {
    [_saveTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
