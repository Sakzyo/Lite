#import "LTModel.h"

NSString *LTUUID(void) {
    return NSUUID.UUID.UUIDString;
}
NSError *LTError(NSString *message) {
    return [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSString *S(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
BOOL LTValidURL(NSString *text) {
    NSURLComponents *u = [NSURLComponents componentsWithString:text];
    if ([@[ @"http", @"https" ] containsObject:u.scheme.lowercaseString])
        return u.host.length > 0 && !u.user.length && !u.password.length;
    return [text isEqual:@"about:blank"] || ([u.scheme isEqual:@"chrome"] && u.host.length > 0);
}
NSString *LTURLFromInput(NSString *input, NSString *provider) {
    NSString *text =
        [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (LTValidURL(text))
        return text;
    if ([text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location ==
            NSNotFound &&
        ([text containsString:@"."] || [text hasPrefix:@"localhost"] ||
         [text hasPrefix:@"[::1]"])) {
        NSString *candidate = [([text hasPrefix:@"localhost"] || [text hasPrefix:@"127.0.0.1"]
                                    ? @"http://"
                                    : @"https://") stringByAppendingString:text];
        if (LTValidURL(candidate))
            return candidate;
    }
    return LTSearchURL(text, provider);
}
NSString *LTSearchURL(NSString *query, NSString *provider) {
    NSURLComponents *u = [NSURLComponents
        componentsWithString:[provider isEqual:@"Google"] ? @"https://www.google.com/search"
                                                          : @"https://duckduckgo.com/"];
    u.queryItems = @[ [NSURLQueryItem queryItemWithName:@"q" value:query] ];
    return u.URL.absoluteString;
}
@implementation LTNode
- (instancetype)init {
    if ((self = [super init])) {
        _identifier = LTUUID();
        _kind = @"temporary";
        _spaceID = @"";
        _parentID = @"";
        _title = @"New Tab";
        _customTitle = @"";
        _url = @"about:blank";
        _pinnedURL = @"";
        _favicon = @"";
        _expanded = YES;
        _lastUsed = NSDate.date.timeIntervalSince1970;
    }
    return self;
}
- (NSString *)displayTitle {
    return self.customTitle.length ? self.customTitle : (self.title.length ? self.title : self.url);
}
+ (instancetype)fromJSON:(NSDictionary *)j {
    LTNode *n = [self new];
    n.identifier = S(j[@"id"]);
    n.kind = S(j[@"kind"]);
    n.spaceID = S(j[@"space"]);
    n.parentID = S(j[@"parent"]);
    n.title = S(j[@"title"]);
    n.customTitle = S(j[@"customTitle"]);
    n.url = S(j[@"url"]);
    n.pinnedURL = S(j[@"pinnedURL"]);
    n.favicon = S(j[@"favicon"]);
    n.order = [j[@"order"] integerValue];
    n.expanded = j[@"expanded"] ? [j[@"expanded"] boolValue] : YES;
    n.lastUsed = [j[@"lastUsed"] doubleValue];
    return n;
}
- (NSDictionary *)JSON {
    return @{
        @"id" : _identifier,
        @"kind" : _kind,
        @"space" : _spaceID,
        @"parent" : _parentID,
        @"title" : _title,
        @"customTitle" : _customTitle,
        @"url" : _url,
        @"pinnedURL" : _pinnedURL,
        @"favicon" : _favicon,
        @"order" : @(_order),
        @"expanded" : @(_expanded),
        @"lastUsed" : @(_lastUsed)
    };
}
@end
@implementation LTSpace
- (instancetype)init {
    if ((self = [super init])) {
        _identifier = LTUUID();
        _name = @"New Space";
        _selectedID = @"";
    }
    return self;
}
+ (instancetype)fromJSON:(NSDictionary *)j {
    LTSpace *s = [self new];
    s.identifier = S(j[@"id"]);
    s.name = S(j[@"name"]);
    s.selectedID = S(j[@"selected"]);
    return s;
}
- (NSDictionary *)JSON {
    return @{@"id" : _identifier, @"name" : _name, @"selected" : _selectedID};
}
@end
@implementation LTProfile
- (instancetype)init {
    if ((self = [super init])) {
        _spaces = [NSMutableArray new];
        _nodes = [NSMutableArray new];
        _settings = [NSMutableDictionary new];
        _windows = [NSMutableArray new];
        _activeSpaceID = @"";
    }
    return self;
}
+ (instancetype)fresh {
    LTProfile *p = [self new];
    p.activeSpaceID = [p addSpace:@"Personal"].identifier;
    p.settings = [@{
        @"performance" : @"Efficient",
        @"search" : @"DuckDuckGo",
        @"externalMini" : @YES,
        @"onboarded" : @NO
    } mutableCopy];
    return p;
}
+ (instancetype)fromJSON:(NSDictionary *)j error:(NSError **)error {
    if (![j isKindOfClass:NSDictionary.class] || ![j[@"version"] isEqual:@1] ||
        ![j[@"spaces"] isKindOfClass:NSArray.class] || ![j[@"nodes"] isKindOfClass:NSArray.class]) {
        if (error)
            *error = LTError(
                @"Unsupported or damaged Lite profile. The original database was preserved.");
        return nil;
    }
    LTProfile *p = [self new];
    for (id s in j[@"spaces"]) {
        if (![s isKindOfClass:NSDictionary.class])
            return nil;
        [p.spaces addObject:[LTSpace fromJSON:s]];
    }
    for (id n in j[@"nodes"]) {
        if (![n isKindOfClass:NSDictionary.class])
            return nil;
        [p.nodes addObject:[LTNode fromJSON:n]];
    }
    if ([j[@"settings"] isKindOfClass:NSDictionary.class])
        p.settings = [j[@"settings"] mutableCopy];
    if ([j[@"windows"] isKindOfClass:NSArray.class])
        p.windows = [j[@"windows"] mutableCopy];
    p.activeSpaceID = S(j[@"activeSpace"]);
    return [p validate:error] ? p : nil;
}
- (NSDictionary *)JSON {
    NSMutableArray *spaces = [NSMutableArray new], *nodes = [NSMutableArray new];
    for (LTSpace *s in _spaces)
        [spaces addObject:s.JSON];
    for (LTNode *n in _nodes)
        [nodes addObject:n.JSON];
    return @{
        @"version" : @1,
        @"spaces" : spaces,
        @"nodes" : nodes,
        @"activeSpace" : _activeSpaceID,
        @"settings" : _settings,
        @"windows" : _windows
    };
}
- (LTNode *)node:(NSString *)identifier {
    for (LTNode *n in _nodes)
        if ([n.identifier isEqual:identifier])
            return n;
    return nil;
}
- (LTSpace *)space:(NSString *)identifier {
    for (LTSpace *s in _spaces)
        if ([s.identifier isEqual:identifier])
            return s;
    return nil;
}
- (NSArray<LTNode *> *)children:(NSString *)parent space:(NSString *)space kind:(NSString *)kind {
    NSMutableArray *a = [NSMutableArray new];
    for (LTNode *n in _nodes)
        if ([n.parentID isEqual:parent] && [n.spaceID isEqual:space] &&
            (!kind || [n.kind isEqual:kind]))
            [a addObject:n];
    return [a sortedArrayUsingComparator:^NSComparisonResult(LTNode *a, LTNode *b) {
      if (a.order != b.order)
          return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
      return [a.identifier compare:b.identifier];
    }];
}
- (LTSpace *)addSpace:(NSString *)name {
    LTSpace *s = [LTSpace new];
    s.name = name;
    [_spaces addObject:s];
    return s;
}
- (LTNode *)addNode:(NSString *)kind
              title:(NSString *)title
                url:(NSString *)url
              space:(NSString *)space
             parent:(NSString *)parent {
    LTNode *n = [LTNode new];
    n.kind = kind;
    n.title = title;
    n.url = url;
    n.spaceID = space;
    n.parentID = parent;
    n.pinnedURL = [kind isEqual:@"pinned"] ? url : @"";
    n.order = 0;
    for (LTNode *s in [self children:parent space:space kind:nil])
        n.order = MAX(n.order, s.order + 1);
    [_nodes addObject:n];
    return n;
}
- (BOOL)moveNode:(NSString *)identifier
           space:(NSString *)space
          parent:(NSString *)parent
           index:(NSInteger)index
           error:(NSError **)error {
    LTNode *n = [self node:identifier];
    LTNode *target = [self node:parent];
    if (!n || (![n.kind isEqual:@"favorite"] && ![self space:space]) ||
        (parent.length &&
         (!target || ![target.kind isEqual:@"folder"] || ![target.spaceID isEqual:space]))) {
        if (error)
            *error = LTError(@"That destination no longer exists.");
        return NO;
    }
    NSString *cursor = parent;
    while (cursor.length) {
        if ([cursor isEqual:identifier]) {
            if (error)
                *error = LTError(@"A folder cannot contain itself.");
            return NO;
        }
        cursor = [self node:cursor].parentID;
    }
    NSMutableSet *descendants = [NSMutableSet setWithObject:identifier];
    BOOL added = YES;
    while (added) {
        added = NO;
        for (LTNode *child in _nodes)
            if ([descendants containsObject:child.parentID] &&
                ![descendants containsObject:child.identifier]) {
                [descendants addObject:child.identifier];
                added = YES;
            }
    }
    for (LTNode *child in _nodes)
        if ([descendants containsObject:child.identifier])
            child.spaceID = space;
    n.parentID = parent;
    if (parent.length && [n.kind isEqual:@"temporary"]) {
        n.kind = @"pinned";
        n.pinnedURL = n.url;
    }
    NSMutableArray *siblings = [[self children:parent space:space kind:nil] mutableCopy];
    [siblings removeObject:n];
    [siblings insertObject:n atIndex:MIN(MAX(index, 0), (NSInteger)siblings.count)];
    [siblings enumerateObjectsUsingBlock:^(LTNode *s, NSUInteger i, BOOL *stop) {
      s.order = i;
    }];
    for (LTSpace *s in _spaces)
        if ([descendants containsObject:s.selectedID] && ![s.identifier isEqual:space])
            s.selectedID = @"";
    return YES;
}
- (void)removeNode:(NSString *)identifier {
    if (self.settings[@"githubLiveFolders"][identifier]) {
        NSMutableDictionary *folders = [self.settings[@"githubLiveFolders"] mutableCopy];
        [folders removeObjectForKey:identifier];
        self.settings[@"githubLiveFolders"] = folders;
    }
    NSArray *copy = [_nodes copy];
    for (LTNode *n in copy)
        if ([n.parentID isEqual:identifier])
            [self removeNode:n.identifier];
    LTNode *n = [self node:identifier];
    if (n)
        [_nodes removeObject:n];
    for (LTSpace *s in _spaces)
        if ([s.selectedID isEqual:identifier])
            s.selectedID = @"";
}
- (void)removeSpace:(NSString *)identifier {
    if (_spaces.count <= 1)
        return;
    for (LTNode *n in [_nodes copy])
        if ([n.spaceID isEqual:identifier])
            [_nodes removeObject:n];
    LTSpace *s = [self space:identifier];
    if (s)
        [_spaces removeObject:s];
    if ([_activeSpaceID isEqual:identifier])
        _activeSpaceID = _spaces.firstObject.identifier;
}
- (BOOL)validate:(NSError **)error {
    NSString *problem = nil;
    NSMutableSet *ids = [NSMutableSet new];
    NSMutableDictionary *nodes = [NSMutableDictionary new];
    NSMutableSet *spaces = [NSMutableSet new];
    if (!_spaces.count)
        problem = @"A profile needs at least one Space.";
    for (LTSpace *s in _spaces) {
        if (!s.identifier.length || [ids containsObject:s.identifier] || !s.name.length)
            problem = @"Duplicate or invalid Space.";
        [ids addObject:s.identifier];
        [spaces addObject:s.identifier];
    }
    for (LTNode *n in _nodes) {
        if (!n.identifier.length || [ids containsObject:n.identifier])
            problem = @"Duplicate or invalid item identifier.";
        [ids addObject:n.identifier];
        nodes[n.identifier] = n;
    }
    if (![spaces containsObject:_activeSpaceID])
        problem = @"The selected Space is missing.";
    for (LTNode *n in _nodes) {
        if (![@[ @"folder", @"pinned", @"temporary", @"favorite" ] containsObject:n.kind])
            problem = @"Unknown sidebar item type.";
        if ([n.kind isEqual:@"favorite"]) {
            if (n.spaceID.length || n.parentID.length)
                problem = @"Favorites must be global.";
        } else if (![spaces containsObject:n.spaceID])
            problem = @"An item's Space is missing.";
        if (![n.kind isEqual:@"folder"] && !LTValidURL(n.url))
            problem = @"Invalid or unsupported page URL.";
        if (n.pinnedURL.length && !LTValidURL(n.pinnedURL))
            problem = @"Invalid pinned URL.";
        if (n.parentID.length) {
            LTNode *p = nodes[n.parentID];
            if (!p || ![p.kind isEqual:@"folder"] || ![p.spaceID isEqual:n.spaceID] ||
                [n.kind isEqual:@"temporary"])
                problem = @"Invalid folder relationship.";
        }
        NSMutableSet *visited = [NSMutableSet new];
        NSString *cursor = n.identifier;
        while (cursor.length) {
            if ([visited containsObject:cursor]) {
                problem = @"Folder cycle detected.";
                break;
            }
            [visited addObject:cursor];
            cursor = ((LTNode *)nodes[cursor]).parentID;
        }
    }
    for (LTSpace *s in _spaces)
        if (s.selectedID.length) {
            LTNode *n = nodes[s.selectedID];
            if (!n || [n.kind isEqual:@"folder"] ||
                (![n.kind isEqual:@"favorite"] && ![n.spaceID isEqual:s.identifier]))
                problem = @"Invalid selected tab.";
        }
    if (problem && error)
        *error = LTError(problem);
    return problem == nil;
}
@end
