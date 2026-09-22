#import "LTCommandIndex.h"
NSInteger LTFuzzyScore(NSString *query, NSString *text) {
    NSString *q = query.lowercaseString, *t = text.lowercaseString;
    if (!q.length)
        return 1;
    if ([q isEqual:t])
        return 1000;
    if ([t hasPrefix:q])
        return 700;
    if ([t containsString:q])
        return 500;
    NSUInteger pos = 0;
    NSInteger score = 100;
    for (NSUInteger i = 0; i < q.length; i++) {
        NSRange r = [t rangeOfString:[q substringWithRange:NSMakeRange(i, 1)]
                             options:0
                               range:NSMakeRange(pos, t.length - pos)];
        if (r.location == NSNotFound)
            return 0;
        score -= MIN(10, r.location - pos);
        pos = NSMaxRange(r);
    }
    return MAX(1, score);
}
NSArray<NSDictionary *> *LTCommandResults(NSString *query, LTProfile *profile,
                                          NSArray<NSDictionary *> *history,
                                          NSSet<NSString *> *openIDs) {
    NSMutableArray *r = [NSMutableArray new];
    NSString *q =
        [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    void (^add)(NSString *, NSString *, NSString *, NSString *, NSInteger, NSString *) =
        ^(NSString *title, NSString *detail, NSString *type, NSString *value, NSInteger rank,
          NSString *icon) {
          [r addObject:@{
              @"title" : title,
              @"detail" : detail,
              @"type" : type,
              @"value" : value,
              @"rank" : @(rank),
              @"icon" : icon
          }];
        };
    NSString *searchURL = LTSearchURL(q, profile.settings[@"search"]);
    NSString *address = LTURLFromInput(q, profile.settings[@"search"]);
    if (q.length && ![address isEqual:searchURL])
        add(address, @"Open address", @"url", address, 30000, @"globe");
    for (LTNode *n in profile.nodes) {
        if ([n.kind isEqual:@"folder"])
            continue;
        BOOL exact =
            q.length && ([q isEqual:n.url] || [q isEqual:n.displayTitle] || [q isEqual:n.title]);
        if (q.length && !exact)
            continue;
        BOOL open = [openIDs containsObject:n.identifier];
        NSInteger rank = (exact ? 20000 : 0) + (open                           ? 8000
                                                : [n.kind isEqual:@"favorite"] ? 7000
                                                : [n.kind isEqual:@"pinned"]   ? 6000
                                                                               : 7500);
        add(n.displayTitle,
            [NSString stringWithFormat:@"%@ · %@",
                                       open                           ? @"Switch to tab"
                                       : [n.kind isEqual:@"favorite"] ? @"Favorite"
                                                                      : @"Pinned tab",
                                       [NSURL URLWithString:n.url].host ?: n.url],
            @"tab", n.identifier, rank, open ? @"rectangle.on.rectangle" : @"globe");
    }
    for (LTSpace *s in profile.spaces) {
        NSInteger score = LTFuzzyScore(q, s.name);
        if (score)
            add(s.name, @"Switch Space", @"space", s.identifier, 5500 + score, @"square.grid.2x2");
    }
    for (NSDictionary *h in history) {
        BOOL exact = q.length && ([q isEqual:h[@"title"]] || [q isEqual:h[@"url"]]);
        if (!q.length || exact)
            add([h[@"title"] length] ? h[@"title"] : h[@"url"], h[@"url"], @"url", h[@"url"],
                exact ? 24000 : 4000, @"clock");
    }
    NSArray *commands = @[
        @[ @"New Tab", @"newTab", @"plus" ],
        @[ @"New Window", @"newWindow", @"macwindow" ],
        @[ @"New Private Window", @"newPrivate", @"hand.raised" ],
        @[ @"New Space", @"newSpace", @"square.grid.2x2" ],
        @[ @"New Folder", @"newFolder", @"folder.badge.plus" ],
        @[ @"New GitHub Live Folder", @"githubFolder", @"arrow.triangle.branch" ],
        @[ @"Browser Task Manager", @"taskManager", @"gauge.with.dots.needle.33percent" ],
        @[ @"Content Blocking", @"contentBlocking", @"shield.lefthalf.filled" ],
        @[ @"Keyboard Shortcuts", @"shortcuts", @"keyboard" ],
        @[ @"Pin / Unpin Tab", @"pinTab", @"pin" ],
        @[ @"Move Tab to Space…", @"moveTab", @"arrow.right.square" ],
        @[ @"Close Tab", @"closeTab", @"xmark" ],
        @[ @"Reopen Closed Tab", @"reopenTab", @"arrow.uturn.backward" ],
        @[ @"Split Right", @"splitRight", @"rectangle.split.2x1" ],
        @[ @"Split Down", @"splitDown", @"rectangle.split.1x2" ],
        @[ @"Close Split", @"closeSplit", @"rectangle" ],
        @[ @"Show Downloads", @"downloads", @"arrow.down.circle" ],
        @[ @"Show History", @"history", @"clock" ],
        @[ @"Show Settings", @"settings", @"gearshape" ],
        @[ @"Save Login for This Site", @"saveLogin", @"key" ],
        @[ @"Fill from Apple Keychain", @"fillLogin", @"key.fill" ],
        @[ @"Open Apple Passwords", @"applePasswords", @"key" ],
        @[ @"Manage Saved Logins", @"passwords", @"lock" ],
        @[ @"Open Google Password Manager", @"googlePasswords", @"globe" ],
        @[ @"Clear Browsing Data", @"clearData", @"trash" ],
        @[ @"Enter Full Screen", @"fullScreen", @"arrow.up.left.and.arrow.down.right" ],
        @[ @"Import from Arc", @"importArc", @"square.and.arrow.down" ],
        @[ @"Picture in Picture", @"pip", @"pip.enter" ],
        @[ @"Show Developer Tools", @"devTools", @"chevron.left.forwardslash.chevron.right" ]
    ];
    for (NSArray *c in commands) {
        NSInteger score = LTFuzzyScore(q, c[0]);
        if (score)
            add(c[0], @"Browser command", @"command", c[1], 3000 + score, c[2]);
    }
    if (q.length)
        add([@"Search for “" stringByAppendingFormat:@"%@”", q],
            profile.settings[@"search"] ?: @"DuckDuckGo", @"url", searchURL, 15000,
            @"magnifyingglass");
    [r sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      NSComparisonResult c = [b[@"rank"] compare:a[@"rank"]];
      return c == NSOrderedSame ? [a[@"title"] compare:b[@"title"]] : c;
    }];
    return r.count > 30 ? [r subarrayWithRange:NSMakeRange(0, 30)] : r;
}
