// Auto-archive: the Settings choices, which temporary tabs count as idle, what is always kept,
// tabs from older profiles, and that archived tabs land in Recently Closed and survive a reload.
#import "../model/LTStore.h"
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

static const double Day = 86400;
static LTNode *Tab(LTProfile *profile, NSString *url, double used) {
    LTNode *node = [profile addNode:@"temporary" title:url url:url space:profile.activeSpaceID parent:@""];
    node.lastUsed = used;
    return node;
}

int main(void) {
    @autoreleasepool {
        CHECK([LTArchiveChoices().firstObject isEqual:@"Never"] && LTArchiveChoices().count == 5,
              "Settings offers Never first, then four periods");
        CHECK(LTArchiveInterval(nil) == 0 && LTArchiveInterval(@{}) == 0 &&
                  LTArchiveInterval(@{@"archiveTabs" : @"Never"}) == 0 &&
                  LTArchiveInterval(@{@"archiveTabs" : @"2 Days"}) == 0 &&
                  LTArchiveInterval(@{@"archiveTabs" : @7}) == 0,
              "archiving is off by default and for unknown values");
        CHECK(LTArchiveInterval(@{@"archiveTabs" : @"12 Hours"}) == Day / 2 &&
                  LTArchiveInterval(@{@"archiveTabs" : @"1 Day"}) == Day &&
                  LTArchiveInterval(@{@"archiveTabs" : @"7 Days"}) == 7 * Day &&
                  LTArchiveInterval(@{@"archiveTabs" : @"30 Days"}) == 30 * Day,
              "each period maps to its length");

        LTProfile *profile = [LTProfile fresh];
        double now = 1000 * Day;
        LTNode *old = Tab(profile, @"https://old.example/", now - 3 * Day);
        LTNode *older = Tab(profile, @"https://older.example/", now - 9 * Day);
        LTNode *fresh = Tab(profile, @"https://fresh.example/", now - Day / 2);
        LTNode *edge = Tab(profile, @"https://edge.example/", now - Day);
        LTNode *shown = Tab(profile, @"https://shown.example/", now - 5 * Day);
        LTNode *selected = Tab(profile, @"https://selected.example/", now - 5 * Day);
        LTNode *legacy = Tab(profile, @"https://legacy.example/", 0);
        LTNode *pinned = [profile addNode:@"pinned" title:@"p" url:@"https://pinned.example/" space:profile.activeSpaceID parent:@""];
        pinned.lastUsed = now - 90 * Day;
        LTNode *favorite = [profile addNode:@"favorite" title:@"f" url:@"https://fav.example/" space:@"" parent:@""];
        favorite.lastUsed = now - 90 * Day;
        [profile space:profile.activeSpaceID].selectedID = selected.identifier;
        NSSet *inUse = [NSSet setWithObject:shown.identifier];

        CHECK([profile idleTabsAt:now excluding:inUse].count == 0, "nothing is archived while archiving is off");
        profile.settings[@"archiveTabs"] = @"1 Day";
        NSArray *idle = [profile idleTabsAt:now excluding:inUse];
        CHECK([idle isEqual:(@[ older.identifier, old.identifier, edge.identifier ])],
              "idle temporary tabs are listed oldest first, including one exactly at the limit");
        CHECK(![idle containsObject:fresh.identifier], "a tab used within the period is kept");
        CHECK(![idle containsObject:shown.identifier], "a tab a window shows or keeps busy is kept");
        CHECK(![idle containsObject:selected.identifier], "each Space's selected tab is kept");
        CHECK(![idle containsObject:pinned.identifier] && ![idle containsObject:favorite.identifier],
              "pinned tabs and Favorites are never archived");
        CHECK(![idle containsObject:legacy.identifier], "a tab with no recorded use is not archived at once");
        CHECK([profile stampUnusedTabs:now] && legacy.lastUsed == now && old.lastUsed == now - 3 * Day &&
                  ![profile stampUnusedTabs:now],
              "tabs from older profiles start aging from the first sweep");
        CHECK([[profile idleTabsAt:now + Day excluding:inUse] containsObject:legacy.identifier],
              "a stamped tab is archived once a full period passes");
        profile.settings[@"archiveTabs"] = @"30 Days";
        CHECK([profile idleTabsAt:now excluding:inUse].count == 0, "a longer period keeps every tab here");

        profile.settings[@"archiveTabs"] = @"1 Day";
        NSError *error = nil;
        CHECK([profile validate:&error], "a profile with an archive setting validates");
        profile.settings[@"archiveTabs"] = @"Sometimes";
        CHECK(![profile validate:&error], "an unknown archive setting is rejected");
        profile.settings[@"archiveTabs"] = @"1 Day";

        // Archive the way the app does when no window has the page open, then reload from disk.
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:LTUUID()];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:@"Lite.sqlite"];
        LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
        if (!store) { NSLog(@"store: %@", error); return 2; }
        [store waitForWrites];
        __block NSString *archivedID = nil;
        [store commit:^(LTProfile *p) {
          p.settings[@"archiveTabs"] = @"1 Day";
          LTNode *tab = Tab(p, @"https://archive.example/page", now - 2 * Day);
          archivedID = tab.identifier;
        } completion:nil];
        [store waitForWrites];
        NSArray *storeIdle = [store.profile idleTabsAt:now excluding:[NSSet set]];
        CHECK([storeIdle containsObject:archivedID], "the stored tab is idle");
        [store commit:^(LTProfile *p) {
          for (NSString *identifier in storeIdle) {
              LTNode *n = [p node:identifier];
              [p noteClosedTab:n time:now];
              [p removeNode:identifier];
          }
        } completion:nil];
        [store waitForWrites];
        [store close];
        LTStore *reopened = [[LTStore alloc] initWithPath:path error:&error];
        [reopened waitForWrites];
        NSDictionary *entry = [reopened.profile latestClosed:@"tab"];
        CHECK(![reopened.profile node:archivedID] &&
                  [entry[@"node"][@"url"] isEqual:@"https://archive.example/page"],
              "an archived tab leaves the sidebar and can be reopened after relaunch");
        [reopened close];
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];

        printf("\n%d passed, %d failed\n", passed, failed);
        return failed ? 1 : 0;
    }
}
