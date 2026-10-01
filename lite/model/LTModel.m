#import "LTModel.h"
#include <math.h>
#include <float.h>

NSString *LTUUID(void) {
    return NSUUID.UUID.UUIDString;
}
NSError *LTError(NSString *message) {
    return [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSString *S(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static BOOL Number(id value, double minimum, double maximum, BOOL integer) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return NO;
    double n = [value doubleValue];
    return isfinite(n) && n >= minimum && n <= maximum && (!integer || trunc(n) == n);
}
static BOOL BoolValue(id value) {
    return [value isKindOfClass:NSNumber.class] && ([value isEqual:@0] || [value isEqual:@1]);
}
static BOOL Strings(NSDictionary *object, NSArray<NSString *> *keys, BOOL required) {
    for (NSString *key in keys)
        if ((required || object[key]) && ![object[key] isKindOfClass:NSString.class]) return NO;
    return YES;
}
static BOOL JSONTree(id value, NSUInteger depth) {
    if (depth > 24) return NO;
    if ([value isKindOfClass:NSString.class]) return [value length] <= 1024 * 1024;
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]);
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value)
            if (![key isKindOfClass:NSString.class] || !JSONTree(value[key], depth + 1)) return NO;
        return YES;
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) if (!JSONTree(item, depth + 1)) return NO;
        return YES;
    }
    return NO;
}
static BOOL Settings(NSDictionary *settings) {
    if (![settings isKindOfClass:NSDictionary.class] || !JSONTree(settings, 0) ||
        !Strings(settings, @[@"performance", @"search"], NO)) return NO;
    if (settings[@"performance"] && ![@[@"Balanced", @"Efficient", @"Maximum Saving"] containsObject:settings[@"performance"]]) return NO;
    if (settings[@"search"] && ![@[@"DuckDuckGo", @"Google"] containsObject:settings[@"search"]]) return NO;
    for (NSString *key in @[@"externalMini", @"onboarded"])
        if (settings[key] && !BoolValue(settings[key])) return NO;
    NSDictionary *blocking = settings[@"contentBlocking"];
    if (blocking) {
        if (![blocking isKindOfClass:NSDictionary.class]) return NO;
        for (NSString *key in @[@"disabled", @"cosmeticDisabled"])
            if (blocking[key] && !BoolValue(blocking[key])) return NO;
        if (blocking[@"disabledSites"]) {
            if (![blocking[@"disabledSites"] isKindOfClass:NSArray.class]) return NO;
            for (id host in blocking[@"disabledSites"])
                if (![host isKindOfClass:NSString.class] || ![host length]) return NO;
        }
    }
    NSDictionary *shortcuts = settings[@"shortcuts"];
    if (shortcuts) {
        if (![shortcuts isKindOfClass:NSDictionary.class]) return NO;
        for (id key in shortcuts) {
            NSDictionary *binding = shortcuts[key];
            if (![binding isKindOfClass:NSDictionary.class] || !Strings(binding, @[@"key"], YES) ||
                !Number(binding[@"modifiers"], 0, UINT32_MAX, YES)) return NO;
        }
    }
    NSDictionary *folders = settings[@"githubLiveFolders"];
    if (folders) {
        if (![folders isKindOfClass:NSDictionary.class]) return NO;
        for (id key in folders) {
            NSDictionary *folder = folders[key];
            if (![folder isKindOfClass:NSDictionary.class] ||
                !Strings(folder, @[@"username", @"repository", @"mode", @"draft"], YES) ||
                (folder[@"updated"] && !Number(folder[@"updated"], 0, DBL_MAX, NO))) return NO;
            if (![@[@"authored", @"review", @"assigned", @"repository"] containsObject:folder[@"mode"]] ||
                ![@[@"all", @"ready", @"draft"] containsObject:folder[@"draft"]]) return NO;
            NSDictionary *items = folder[@"items"];
            if (items) {
                if (![items isKindOfClass:NSDictionary.class]) return NO;
                for (id url in items) if (![items[url] isKindOfClass:NSString.class] || !LTValidURL(url)) return NO;
            }
        }
    }
    return YES;
}
static BOOL Windows(NSArray *windows) {
    if (![windows isKindOfClass:NSArray.class] || windows.count > 256) return NO;
    for (NSDictionary *window in windows) {
        if (![window isKindOfClass:NSDictionary.class] || !JSONTree(window, 0) ||
            !Strings(window, @[@"space", @"active", @"secondary", @"frame"], NO)) return NO;
        for (NSString *key in @[@"vertical", @"sidebarCollapsed", @"deferPages"])
            if (window[key] && !BoolValue(window[key])) return NO;
        if (window[@"ratio"] && !Number(window[@"ratio"], 0, 1, NO)) return NO;
        if (window[@"sidebarWidth"] && !Number(window[@"sidebarWidth"], 0, 10000, NO)) return NO;
        if (window[@"frame"]) {
            NSRect frame = NSRectFromString(window[@"frame"]);
            if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) ||
                !isfinite(frame.size.height) || frame.size.width <= 0 || frame.size.height <= 0 ||
                frame.size.width > 100000 || frame.size.height > 100000) return NO;
        }
        NSDictionary *sessions = window[@"sessions"];
        if (sessions) {
            if (![sessions isKindOfClass:NSDictionary.class] || sessions.count > 100000) return NO;
            for (id key in sessions) {
                NSDictionary *state = sessions[key];
                if (![state isKindOfClass:NSDictionary.class] || !Strings(state, @[@"url"], YES) ||
                    !LTValidURL(state[@"url"]) || !Number(state[@"scrollX"], 0, 1e7, NO) ||
                    !Number(state[@"scrollY"], 0, 1e7, NO) || (state[@"restorable"] && !BoolValue(state[@"restorable"]))) return NO;
            }
        }
    }
    return YES;
}
static BOOL NodeFields(NSDictionary *node) {
    if (![node isKindOfClass:NSDictionary.class] ||
        !Strings(node, @[@"id", @"kind", @"space", @"title", @"url"], YES) ||
        !Strings(node, @[@"parent", @"customTitle", @"pinnedURL", @"favicon"], NO)) return NO;
    if (node[@"order"] && !Number(node[@"order"], 0, INT32_MAX, YES)) return NO;
    if (node[@"expanded"] && !BoolValue(node[@"expanded"])) return NO;
    return !node[@"lastUsed"] || Number(node[@"lastUsed"], 0, DBL_MAX, NO);
}
static id CopyJSON(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *copy = [NSMutableDictionary new];
        for (id key in value) copy[key] = CopyJSON(value[key]);
        return copy;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *copy = [NSMutableArray new];
        for (id item in value) [copy addObject:CopyJSON(item)];
        return copy;
    }
    return [value copy];
}
BOOL LTValidURL(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
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
    return [self initWithIdentifier:LTUUID()];
}
- (instancetype)initWithIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _identifier = [identifier copy];
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
    if (![j isKindOfClass:NSDictionary.class]) j = @{};
    LTNode *n = [[self alloc] initWithIdentifier:S(j[@"id"])];
    n.identifier = S(j[@"id"]);
    n.kind = S(j[@"kind"]);
    n.spaceID = S(j[@"space"]);
    n.parentID = S(j[@"parent"]);
    n.title = S(j[@"title"]);
    n.customTitle = S(j[@"customTitle"]);
    n.url = S(j[@"url"]);
    n.pinnedURL = S(j[@"pinnedURL"]);
    n.favicon = S(j[@"favicon"]);
    n.order = Number(j[@"order"], 0, INT32_MAX, YES) ? [j[@"order"] integerValue] : 0;
    n.expanded = BoolValue(j[@"expanded"]) ? [j[@"expanded"] boolValue] : YES;
    n.lastUsed = Number(j[@"lastUsed"], 0, DBL_MAX, NO) ? [j[@"lastUsed"] doubleValue] : 0;
    return n;
}
- (id)copyWithZone:(NSZone *)zone {
    LTNode *n = [[[self class] allocWithZone:zone] initWithIdentifier:_identifier];
    n.kind = _kind; n.spaceID = _spaceID; n.parentID = _parentID;
    n.title = _title; n.customTitle = _customTitle; n.url = _url;
    n.pinnedURL = _pinnedURL; n.favicon = _favicon; n.order = _order;
    n.expanded = _expanded; n.lastUsed = _lastUsed;
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
    if (![j isKindOfClass:NSDictionary.class]) j = @{};
    LTSpace *s = [self new];
    s.identifier = S(j[@"id"]);
    s.name = S(j[@"name"]);
    s.selectedID = S(j[@"selected"]);
    return s;
}
- (id)copyWithZone:(NSZone *)zone {
    LTSpace *s = [[[self class] allocWithZone:zone] init];
    s.identifier = _identifier; s.name = _name; s.selectedID = _selectedID;
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
    if (![j isKindOfClass:NSDictionary.class] || !Number(j[@"version"], 1, 1, YES) ||
        ![j[@"spaces"] isKindOfClass:NSArray.class] || ![j[@"nodes"] isKindOfClass:NSArray.class] ||
        [j[@"spaces"] count] > 4096 || [j[@"nodes"] count] > 100000 ||
        !Strings(j, @[@"activeSpace"], YES) ||
        (j[@"settings"] && !Settings(j[@"settings"])) || (j[@"windows"] && !Windows(j[@"windows"]))) {
        if (error)
            *error = LTError(
                @"Unsupported or damaged Lite profile. The original database was preserved.");
        return nil;
    }
    LTProfile *p = [self new];
    for (id s in j[@"spaces"]) {
        if (![s isKindOfClass:NSDictionary.class] || !Strings(s, @[@"id", @"name"], YES) || !Strings(s, @[@"selected"], NO)) {
            if (error) *error = LTError(@"A saved Space has invalid fields. The original database was preserved.");
            return nil;
        }
        [p.spaces addObject:[LTSpace fromJSON:s]];
    }
    for (id n in j[@"nodes"]) {
        if (!NodeFields(n)) {
            if (error) *error = LTError(@"A saved sidebar item has invalid fields. The original database was preserved.");
            return nil;
        }
        [p.nodes addObject:[LTNode fromJSON:n]];
    }
    if ([j[@"settings"] isKindOfClass:NSDictionary.class])
        p.settings = [j[@"settings"] mutableCopy];
    if ([j[@"windows"] isKindOfClass:NSArray.class])
        p.windows = [j[@"windows"] mutableCopy];
    p.activeSpaceID = S(j[@"activeSpace"]);
    return [p validate:error] ? p : nil;
}
- (LTProfile *)transactionCopy {
    LTProfile *p = [LTProfile new];
    for (LTSpace *space in _spaces) [p.spaces addObject:[space copy]];
    for (LTNode *node in _nodes) [p.nodes addObject:[node copy]];
    p.settings = CopyJSON(_settings);
    p.windows = CopyJSON(_windows);
    p.activeSpaceID = _activeSpaceID;
    return p;
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
    if (![_spaces isKindOfClass:NSArray.class] || ![_nodes isKindOfClass:NSArray.class] ||
        ![_activeSpaceID isKindOfClass:NSString.class] || !Settings(_settings) || !Windows(_windows) ||
        _spaces.count > 4096 || _nodes.count > 100000) {
        if (error) *error = LTError(@"Invalid profile, settings, or window fields. Your previous data is intact.");
        return NO;
    }
    for (LTSpace *s in _spaces) {
        if (![s isKindOfClass:LTSpace.class] || ![s.identifier isKindOfClass:NSString.class] ||
            ![s.name isKindOfClass:NSString.class] || ![s.selectedID isKindOfClass:NSString.class]) {
            if (error) *error = LTError(@"Invalid Space fields. Your previous data is intact.");
            return NO;
        }
    }
    for (LTNode *n in _nodes) {
        if (![n isKindOfClass:LTNode.class] || ![n.identifier isKindOfClass:NSString.class] ||
            ![n.kind isKindOfClass:NSString.class] || ![n.spaceID isKindOfClass:NSString.class] ||
            ![n.parentID isKindOfClass:NSString.class] || ![n.title isKindOfClass:NSString.class] ||
            ![n.customTitle isKindOfClass:NSString.class] || ![n.url isKindOfClass:NSString.class] ||
            ![n.pinnedURL isKindOfClass:NSString.class] || ![n.favicon isKindOfClass:NSString.class] ||
            n.order < 0 || n.order > INT32_MAX || !isfinite(n.lastUsed) || n.lastUsed < 0) {
            if (error) *error = LTError(@"Invalid sidebar item fields. Your previous data is intact.");
            return NO;
        }
    }
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
    NSMutableSet *checkedAncestors = [NSMutableSet new];
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
        while (cursor.length && ![checkedAncestors containsObject:cursor]) {
            if ([visited containsObject:cursor]) {
                problem = @"Folder cycle detected.";
                break;
            }
            [visited addObject:cursor];
            cursor = ((LTNode *)nodes[cursor]).parentID;
        }
        [checkedAncestors unionSet:visited];
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
