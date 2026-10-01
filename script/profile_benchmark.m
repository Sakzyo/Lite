#import <Foundation/Foundation.h>
#import "../lite/model/LTStore.h"
#include <math.h>
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSDictionary *Stats(NSArray<NSNumber *> *values) {
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    double median = ([sorted[(sorted.count - 1) / 2] doubleValue] + [sorted[sorted.count / 2] doubleValue]) / 2;
    return @{ @"median_ms": @(median), @"p95_ms": sorted[(NSUInteger)ceil(sorted.count * 0.95) - 1], @"samples_ms": values };
}
int main(void) { @autoreleasepool {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSNumber *count in @[@2000, @10000]) { @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:LTUUID()];
        NSString *path = [directory stringByAppendingPathComponent:@"Lite.sqlite"];
        NSError *error = nil;
        LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
        BOOL seeded = [store commit:^(LTProfile *p) {
            for (NSInteger i = 0; i < count.integerValue; i++) {
                LTNode *n = [LTNode new]; n.identifier = [NSString stringWithFormat:@"node-%ld", (long)i];
                n.spaceID = p.activeSpaceID; n.kind = @"pinned"; n.title = n.identifier;
                n.url = @"https://example.invalid/profile-fixture"; n.pinnedURL = n.url; n.order = i;
                [p.nodes addObject:n];
            }
        } error:&error];
        if (!seeded) { NSLog(@"%@", error); return 1; }
        NSMutableArray *commits = [NSMutableArray new], *opens = [NSMutableArray new], *serialization = [NSMutableArray new];
        for (NSInteger i = 0; i < 20; i++) { @autoreleasepool {
            double start = Now();
            if (![store commit:^(LTProfile *p) { p.nodes.firstObject.customTitle = [NSString stringWithFormat:@"Edit %ld", (long)i]; } error:&error]) { NSLog(@"%@", error); return 1; }
            [commits addObject:@((Now()-start)*1000)];
            start = Now();
            [NSJSONSerialization dataWithJSONObject:store.profile.JSON options:NSJSONWritingSortedKeys error:&error];
            [serialization addObject:@((Now()-start)*1000)];
            start = Now(); LTStore *reopened = [[LTStore alloc] initWithPath:path error:&error];
            [opens addObject:@((Now()-start)*1000)];
            if (reopened.profile.nodes.count != count.unsignedIntegerValue) return 2;
        }}
        [rows addObject:@{@"nodes": count, @"commit": Stats(commits), @"open": Stats(opens), @"sorted_serialization": Stats(serialization)}];
        store = nil; [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }}
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"workload": @"20 synchronous durable commits editing one title; fixed synthetic pinned nodes; Release -O3; current libLiteCore", @"results": rows} options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
}}
