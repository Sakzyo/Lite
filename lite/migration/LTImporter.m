#import "LTImporter.h"
#import "LTExporter.h"
#include <math.h>
static NSDictionary *D(id v) {
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
static NSArray *A(id v) {
    return [v isKindOfClass:NSArray.class] ? v : @[];
}
static NSString *S(id v) {
    return [v isKindOfClass:NSString.class] ? v : @"";
}
static NSDictionary *Unwrap(id v) {
    NSDictionary *d = D(v);
    return [d[@"value"] isKindOfClass:NSDictionary.class] ? d[@"value"] : d;
}

@implementation LTImportResult
- (NSString *)summary {
    NSUInteger folders = 0, pins = 0, favorites = 0;
    for (LTNode *n in _profile.nodes) {
        if ([n.kind isEqual:@"folder"])
            folders++;
        if ([n.kind isEqual:@"pinned"])
            pins++;
        if ([n.kind isEqual:@"favorite"])
            favorites++;
    }
    return [NSString stringWithFormat:@"%lu Spaces · %lu folders · %lu pinned tabs · %lu Favorites",
                                      _profile.spaces.count, folders, pins, favorites];
}
@end

// Swift Codable dictionaries may appear as objects or alternating key/value
// arrays. Read their discriminators and IDs; never depend on a fixed root offset.
static NSArray<NSDictionary *> *Records(id value, NSError **error) {
    NSMutableArray *out = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    NSArray *entries = nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *e = [NSMutableArray new];
        for (NSString *key in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSMutableDictionary *d = [Unwrap(value[key]) mutableCopy];
            if (!d[@"id"])
                d[@"id"] = key;
            [e addObject:d];
        }
        entries = e;
    } else if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *e = [NSMutableArray new];
        NSString *key = nil;
        for (id entry in value) {
            if ([entry isKindOfClass:NSString.class]) {
                key = entry;
                continue;
            }
            NSDictionary *raw = Unwrap(entry);
            if (raw.count) {
                NSMutableDictionary *d = [raw mutableCopy];
                if (!d[@"id"] && key)
                    d[@"id"] = key;
                [e addObject:d];
            }
            key = nil;
        }
        entries = e;
    } else {
        if (error)
            *error = LTError(@"The import has no recognizable ordered item collection.");
        return nil;
    }
    for (NSDictionary *d in entries) {
        NSString *key = S(d[@"id"]);
        if (!key.length || [seen containsObject:key]) {
            if (error)
                *error =
                    LTError(@"The import contains missing or duplicate IDs. Nothing was imported.");
            return nil;
        }
        [seen addObject:key];
        [out addObject:d];
    }
    return out;
}
static NSString *ContainerID(NSDictionary *s, NSString *kind) {
    NSString *direct = S(s[[kind stringByAppendingString:@"ContainerID"]]);
    if (direct.length)
        return direct;
    for (NSString *field in @[ @"newContainerIDs", @"containerIDs" ]) {
        id value = s[field];
        if ([value isKindOfClass:NSDictionary.class] && S(value[kind]).length)
            return value[kind];
        NSArray *a = A(value);
        for (NSUInteger i = 0; i + 1 < a.count; i++) {
            if (([a[i] isKindOfClass:NSString.class] && [a[i] isEqual:kind]) || D(a[i])[kind]) {
                NSString *found = S(a[i + 1]);
                if (found.length)
                    return found;
            }
        }
    }
    return @"";
}
@interface LTArcParser : NSObject
@property LTProfile *profile;
@property NSMutableArray<NSString *> *warnings;
@property NSDictionary<NSString *, NSDictionary *> *items;
@property NSMutableSet<NSString *> *visited;
@property NSMutableSet<NSString *> *stack;
- (BOOL)walk:(NSString *)identifier
       space:(NSString *)space
      parent:(NSString *)parent
    favorite:(BOOL)favorite
       error:(NSError **)error;
@end
@implementation LTArcParser
- (BOOL)walk:(NSString *)identifier
       space:(NSString *)space
      parent:(NSString *)parent
    favorite:(BOOL)favorite
       error:(NSError **)error {
    NSDictionary *item = _items[identifier];
    if (!item) {
        if (error)
            *error = LTError(@"The sidebar references an item that is missing. Export a fresh copy "
                             @"from Arc and try again.");
        return NO;
    }
    if ([_stack containsObject:identifier]) {
        if (error)
            *error = LTError(@"The sidebar contains a folder cycle. Nothing was imported.");
        return NO;
    }
    if ([_visited containsObject:identifier]) {
        if (error)
            *error = LTError(@"An item has more than one parent. Nothing was imported.");
        return NO;
    }
    [_visited addObject:identifier];
    [_stack addObject:identifier];
    NSDictionary *data = D(item[@"data"]), *tab = D(data[@"tab"]);
    NSString *kind = S(item[@"kind"]);
    NSArray *children = A(item[@"childrenIds"] ?: item[@"childrenIDs"] ?: item[@"children"]);
    NSString *url = S(tab[@"savedURL"] ?: tab[@"url"] ?: item[@"url"]);
    NSString *title = S(item[@"title"]);
    if (!title.length)
        title = S(tab[@"savedTitle"] ?: item[@"name"]);
    if (url.length || tab.count || [kind isEqual:@"tab"]) {
        if (!LTValidURL(url)) {
            [_warnings addObject:@"One tab with an empty or unsupported URL was skipped."];
            [_stack removeObject:identifier];
            return YES;
        }
        LTNode *n=[_profile addNode:favorite?@"favorite":@"pinned" title:title.length?title:[NSURL URLWithString:url].host?:@"Imported Tab" url:url space:favorite?@"":space parent:favorite?@"":parent];
        n.customTitle = S(item[@"title"]);
        n.pinnedURL = url;
    } else {
        BOOL folder = data[@"list"] || data[@"folder"] || data[@"tabGroup"] || data[@"splitView"] ||
                      [kind isEqual:@"folder"];
        if (folder && !favorite) {
            LTNode *n = [_profile addNode:@"folder"
                                    title:title.length ? title : @"Imported Folder"
                                      url:@""
                                    space:space
                                   parent:parent];
            n.expanded = item[@"isCollapsed"] ? ![item[@"isCollapsed"] boolValue] : YES;
            parent = n.identifier;
        } else if (!data[@"itemContainer"] && !folder && children.count == 0)
            [_warnings addObject:@"An unsupported non-page sidebar item was skipped."];
        if (data[@"splitView"])
            [_warnings addObject:@"An imported split was preserved as a folder of its pages."];
        for (id child in children) {
            if (![child isKindOfClass:NSString.class] || ![self walk:child
                                                                space:space
                                                               parent:parent
                                                             favorite:favorite
                                                                error:error])
                return NO;
        }
    }
    [_stack removeObject:identifier];
    return YES;
}
@end
// Reads the nested items of a Lite organization file. Items are created directly, in file order,
// so a large file imports in linear time.
static const NSUInteger OrganizationDepthLimit = 64;
static const NSUInteger OrganizationItemLimit = 100000;
@interface LTOrganizationReader : NSObject
@property LTProfile *profile;
@property NSUInteger count;
@property NSUInteger skipped;
@property (copy) NSString *damaged;
@property (copy) NSString *problem;
- (BOOL)fail:(NSString *)problem;
- (BOOL)optionalString:(NSDictionary *)object key:(NSString *)key;
- (BOOL)tab:(NSDictionary *)tab kind:(NSString *)kind space:(NSString *)space parent:(NSString *)parent;
- (BOOL)items:(id)items space:(NSString *)space parent:(NSString *)parent depth:(NSUInteger)depth;
@end
@implementation LTOrganizationReader {
    NSMutableDictionary<NSString *, NSNumber *> *_nextOrder;
}
- (BOOL)fail:(NSString *)problem {
    if (!_problem)
        _problem = problem;
    return NO;
}
- (BOOL)optionalString:(NSDictionary *)object key:(NSString *)key {
    return !object[key] || [object[key] isKindOfClass:NSString.class];
}
- (BOOL)counted {
    if (++_count > OrganizationItemLimit)
        return [self fail:@"This organization file has more than 100,000 items. Nothing was imported."];
    return YES;
}
- (LTNode *)add:(NSString *)kind title:(NSString *)title url:(NSString *)url space:(NSString *)space parent:(NSString *)parent {
    if (!_nextOrder)
        _nextOrder = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@/%@", space, parent];
    LTNode *n = [LTNode new];
    n.kind = kind;
    n.title = title;
    n.url = url;
    n.spaceID = space;
    n.parentID = parent;
    n.order = [_nextOrder[key] integerValue];
    _nextOrder[key] = @(n.order + 1);
    [_profile.nodes addObject:n];
    return n;
}
- (BOOL)tab:(NSDictionary *)tab kind:(NSString *)kind space:(NSString *)space parent:(NSString *)parent {
    if (![tab[@"url"] isKindOfClass:NSString.class] || ![self optionalString:tab key:@"title"] ||
        ![self optionalString:tab key:@"customTitle"])
        return [self fail:_damaged];
    if (![self counted])
        return NO;
    NSString *url = tab[@"url"];
    if (!LTValidURL(url)) {
        _skipped++;
        return YES;
    }
    NSString *title = S(tab[@"title"]);
    LTNode *n = [self add:kind
                    title:title.length ? title : ([NSURL URLWithString:url].host ?: url)
                      url:url
                    space:space
                   parent:parent];
    n.customTitle = S(tab[@"customTitle"]);
    n.pinnedURL = url;
    return YES;
}
- (BOOL)items:(id)items space:(NSString *)space parent:(NSString *)parent depth:(NSUInteger)depth {
    if (![items isKindOfClass:NSArray.class])
        return [self fail:_damaged];
    if (depth >= OrganizationDepthLimit)
        return [self fail:@"Folders in this organization file are nested more than 64 deep. Nothing "
                          @"was imported."];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class])
            return [self fail:_damaged];
        if ([item[@"type"] isEqual:@"tab"]) {
            if (![self tab:item kind:@"pinned" space:space parent:parent])
                return NO;
        } else if ([item[@"type"] isEqual:@"folder"]) {
            if (![self optionalString:item key:@"title"] ||
                (item[@"open"] && ![item[@"open"] isKindOfClass:NSNumber.class]))
                return [self fail:_damaged];
            if (![self counted])
                return NO;
            NSString *title = S(item[@"title"]);
            LTNode *folder = [self add:@"folder"
                                 title:title.length ? title : @"Imported Folder"
                                   url:@""
                                 space:space
                                parent:parent];
            folder.expanded = item[@"open"] ? [item[@"open"] boolValue] : YES;
            if (![self items:item[@"items"] ?: @[] space:space parent:folder.identifier depth:depth + 1])
                return NO;
        } else
            return [self fail:_damaged];
    }
    return YES;
}
@end
@implementation LTImporter
+ (NSArray<NSURL *> *)discoverArcFiles {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *results = [NSMutableArray new];
    NSArray *roots = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Arc"],
        [NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Containers/company.thebrowser.Browser/Data/"
                                           @"Library/Application Support/Arc"]
    ];
    for (NSString *root in roots) {
        NSURL *base = [NSURL fileURLWithPath:root];
        NSDirectoryEnumerator *e = [fm enumeratorAtURL:base
                            includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                          errorHandler:^BOOL(NSURL *u, NSError *er) {
                                            return YES;
                                          }];
        for (NSURL *u in e) {
            if (e.level > 3) {
                [e skipDescendants];
                continue;
            }
            if ([u.lastPathComponent isEqual:@"StorableSidebar.json"])
                [results addObject:u];
        }
    }
    return results;
}
+ (LTImportResult *)parseArcData:(NSData *)data error:(NSError **)error {
    if (data.length > 64 * 1024 * 1024) {
        if (error)
            *error = LTError(@"This sidebar file exceeds the 64 MB safety limit.");
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error && !*error)
            *error = LTError(@"Choose an Arc sidebar JSON object.");
        return nil;
    }
    NSMutableArray *containers = [NSMutableArray new];
    NSDictionary *sidebar = D(json[@"sidebar"]);
    id raw = sidebar[@"containers"] ?: json[@"containers"];
    if ([raw isKindOfClass:NSArray.class])
        for (id entry in raw) {
            NSDictionary *c = D(entry);
            if (c[@"spaces"] && c[@"items"])
                [containers addObject:c];
        }
    if ([raw isKindOfClass:NSDictionary.class])
        for (id entry in [raw allValues]) {
            NSDictionary *c = D(entry);
            if (c[@"spaces"] && c[@"items"])
                [containers addObject:c];
        }
    if (!containers.count && json[@"spaces"] && json[@"items"])
        [containers addObject:json];
    if (!containers.count) {
        NSDictionary *sync = D(json[@"sidebarSyncState"]);
        if (sync[@"spaceModels"] && sync[@"items"]) {
            NSMutableDictionary *c = [Unwrap(sync[@"container"]) mutableCopy];
            c[@"spaces"] = sync[@"spaceModels"];
            c[@"items"] = sync[@"items"];
            [containers addObject:c];
        }
    }
    if (!containers.count) {
        if (error)
            *error = LTError(@"This Arc sidebar schema is not recognized. The source file has not "
                             @"been changed. Try a newer export or an HTML bookmarks file.");
        return nil;
    }
    LTArcParser *p = [LTArcParser new];
    p.profile = [LTProfile new];
    p.warnings = [NSMutableArray new];
    for (NSDictionary *container in containers) {
        NSArray *items = Records(container[@"items"], error),
                *spaces = Records(container[@"spaces"], error);
        if (!items || !spaces)
            return nil;
        NSMutableDictionary *map = [NSMutableDictionary new];
        for (NSDictionary *item in items)
            map[item[@"id"]] = item;
        p.items = map;
        p.visited = [NSMutableSet new];
        p.stack = [NSMutableSet new];
        NSArray *order = A(container[@"orderedSpaceIDs"]);
        if (order.count) {
            NSMutableArray *ordered = [NSMutableArray new];
            NSMutableSet *seen = [NSMutableSet new];
            for (NSString *sid in order) {
                NSDictionary *found = nil;
                for (NSDictionary *s in spaces)
                    if ([s[@"id"] isEqual:sid])
                        found = s;
                if (!found || [seen containsObject:sid]) {
                    if (error)
                        *error = LTError(@"Invalid Space ordering references.");
                    return nil;
                }
                [ordered addObject:found];
                [seen addObject:sid];
            }
            for (NSDictionary *s in spaces)
                if (![seen containsObject:s[@"id"]])
                    [ordered addObject:s];
            spaces = ordered;
        }
        NSMutableArray *favorites = [NSMutableArray new];
        NSString *fav = S(container[@"topAppsContainerID"] ?: container[@"favoritesContainerID"]);
        if (fav.length)
            [favorites addObject:fav];
        id tops = container[@"topAppsContainerIDs"];
        if ([tops isKindOfClass:NSDictionary.class]) {
            for (id f in [tops allValues])
                if (S(f).length)
                    [favorites addObject:f];
        } else
            for (id f in A(tops))
                if (S(f).length)
                    [favorites addObject:f];
        for (NSString *f in [NSOrderedSet orderedSetWithArray:favorites])
            if (![p.visited containsObject:f] && ![p walk:f
                                                        space:@""
                                                       parent:@""
                                                     favorite:YES
                                                        error:error])
                return nil;
        for (NSDictionary *space in spaces) {
            NSString *name = S(space[@"title"] ?: space[@"name"]);
            LTSpace *s = [p.profile addSpace:name.length ? name : @"Imported Space"];
            NSString *root = ContainerID(space, @"pinned");
            if (root.length) {
                if (![p walk:root space:s.identifier parent:@"" favorite:NO error:error])
                    return nil;
            } else if (space[@"childrenIds"] || space[@"children"]) {
                for (NSString *child in A(space[@"childrenIds"] ?: space[@"children"]))
                    if (![p walk:child space:s.identifier parent:@"" favorite:NO error:error])
                        return nil;
            } else {
                if (error)
                    *error = LTError(@"A Space's pinned container could not be identified. Nothing "
                                     @"was imported.");
                return nil;
            }
        }
    }
    if (!p.profile.spaces.count)
        [p.profile addSpace:@"Personal"];
    p.profile.activeSpaceID = p.profile.spaces.firstObject.identifier;
    if (![p.profile validate:error])
        return nil;
    LTImportResult *r = [LTImportResult new];
    r.profile = p.profile;
    r.warnings = p.warnings;
    return r;
}
+ (void)merge:(LTImportResult *)result into:(LTProfile *)profile {
    // Every preview uses fresh Lite UUIDs. Source IDs never become database IDs.
    [profile.spaces addObjectsFromArray:result.profile.spaces];
    [profile.nodes addObjectsFromArray:result.profile.nodes];
    NSInteger i = 0;
    for (LTNode *n in profile.nodes)
        if ([n.kind isEqual:@"favorite"])
            n.order = i++;
    profile.activeSpaceID = result.profile.activeSpaceID;
    profile.settings[@"onboarded"] = @YES;
    if (result.spaceThemes.count) {
        NSDictionary *saved = profile.settings[@"spaceThemes"];
        NSMutableDictionary *themes =
            [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary new];
        [themes addEntriesFromDictionary:result.spaceThemes];
        profile.settings[@"spaceThemes"] = themes;
    }
}
static void BookmarkTree(id entry, LTProfile *p, NSString *sid, NSString *parent) {
    NSDictionary *d = D(entry);
    NSString *url = S(d[@"url"] ?: d[@"URLString"]);
    NSString *name = S(d[@"name"] ?: d[@"title"] ?: D(d[@"URIDictionary"])[@"title"]);
    if (url.length) {
        if (LTValidURL(url))
            [p addNode:@"pinned" title:name.length ? name : url url:url space:sid parent:parent];
        return;
    }
    NSArray *children = A(d[@"children"] ?: d[@"Children"]);
    if (name.length)
        parent = [p addNode:@"folder" title:name url:@"" space:sid parent:parent].identifier;
    for (id child in children)
        BookmarkTree(child, p, sid, parent);
}
+ (LTImportResult *)parseBookmarks:(NSData *)data
                            format:(NSString *)format
                             error:(NSError **)error {
    if ([format isEqual:@"json"] && data.length <= 64 * 1024 * 1024) {
        id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([D(j)[@"format"] isEqual:LTOrganizationFormat])
            return [self parseOrganization:data error:error];
    }
    LTProfile *p = [LTProfile fresh];
    p.spaces.firstObject.name = @"Bookmarks";
    NSString *sid = p.activeSpaceID;
    NSString *root =
        [p addNode:@"folder" title:@"Imported Bookmarks" url:@"" space:sid parent:@""].identifier;
    if ([format isEqual:@"json"]) {
        id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if (!j)
            return nil;
        NSDictionary *roots = D(D(j)[@"roots"]);
        if (!roots.count) {
            if (error)
                *error = LTError(@"No Chromium bookmark roots were found.");
            return nil;
        }
        for (NSString *key in [[roots allKeys] sortedArrayUsingSelector:@selector(compare:)])
            BookmarkTree(roots[key], p, sid, root);
    } else if ([format isEqual:@"plist"]) {
        id j = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil
                                                           error:error];
        if (!j)
            return nil;
        BookmarkTree(j, p, sid, root);
    } else {
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!html) {
            if (error)
                *error = LTError(@"The bookmarks file must be UTF-8 HTML.");
            return nil;
        }
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:
                @"(?is)<H3\\b[^>]*>(.*?)</"
                @"H3>|<A\\b[^>]*HREF\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</A>|<DL\\b[^>]*>|</DL>"
                                 options:0
                                   error:error];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        __block NSString *pending = nil;
        NSString * (^decode)(NSString *) = ^NSString *(NSString *s) {
          return [[[[[s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]
              stringByReplacingOccurrencesOfString:@"&lt;"
                                        withString:@"<"]
              stringByReplacingOccurrencesOfString:@"&gt;"
                                        withString:@">"]
              stringByReplacingOccurrencesOfString:@"&quot;"
                                        withString:@"\""]
              stringByReplacingOccurrencesOfString:@"&#39;"
                                        withString:@"'"];
        };
        for (NSTextCheckingResult *m in [re matchesInString:html
                                                    options:0
                                                      range:NSMakeRange(0, html.length)]) {
            NSString *token = [html substringWithRange:m.range];
            if ([m rangeAtIndex:1].location != NSNotFound)
                pending = decode([html substringWithRange:[m rangeAtIndex:1]]);
            else if ([m rangeAtIndex:2].location != NSNotFound) {
                NSString *url = decode([html substringWithRange:[m rangeAtIndex:2]]);
                if (LTValidURL(url))
                    [p addNode:@"pinned"
                         title:decode([html substringWithRange:[m rangeAtIndex:3]])
                           url:url
                         space:sid
                        parent:stack.lastObject];
            } else if ([token.lowercaseString hasPrefix:@"</dl"]) {
                if (stack.count > 1)
                    [stack removeLastObject];
            } else {
                NSString *parent = stack.lastObject;
                if (pending) {
                    parent = [p addNode:@"folder" title:pending url:@"" space:sid parent:parent]
                                 .identifier;
                    pending = nil;
                }
                [stack addObject:parent];
            }
        }
    }
    if (p.nodes.count <= 1) {
        if (error)
            *error = LTError(@"No supported bookmarks were found.");
        return nil;
    }
    LTImportResult *r = [LTImportResult new];
    r.profile = p;
    r.warnings = @[];
    return r;
}
+ (LTImportResult *)parseOrganization:(NSData *)data error:(NSError **)error {
    NSString *damaged =
        @"This organization file is damaged or was edited incorrectly. Nothing was imported.";
    if (data.length > 64 * 1024 * 1024) {
        if (error)
            *error = LTError(@"This organization file exceeds the 64 MB safety limit.");
        return nil;
    }
    NSDictionary *j = D([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
    if (![j[@"format"] isEqual:LTOrganizationFormat]) {
        if (error)
            *error = LTError(@"This is not a Lite organization file.");
        return nil;
    }
    id version = j[@"version"];
    if (![version isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        floor([version doubleValue]) != [version doubleValue] || [version doubleValue] < 1) {
        if (error)
            *error = LTError(damaged);
        return nil;
    }
    if ([version doubleValue] > LTOrganizationVersion) {
        if (error)
            *error = LTError(@"This organization file was made by a newer version of Lite. Update "
                             @"Lite and try again.");
        return nil;
    }
    NSArray *spaces = j[@"spaces"];
    id favorites = j[@"favorites"] ?: @[];
    if (![spaces isKindOfClass:NSArray.class] || !spaces.count || spaces.count > 4096 ||
        ![favorites isKindOfClass:NSArray.class]) {
        if (error)
            *error = LTError(damaged);
        return nil;
    }
    LTOrganizationReader *r = [LTOrganizationReader new];
    r.profile = [LTProfile new];
    r.damaged = damaged;
    NSMutableDictionary *themes = [NSMutableDictionary new];
    for (NSDictionary *space in spaces) {
        if (![space isKindOfClass:NSDictionary.class] || ![r optionalString:space key:@"name"] ||
            ![r optionalString:space key:@"theme"] || S(space[@"theme"]).length > 64) {
            [r fail:damaged];
            break;
        }
        NSString *name = S(space[@"name"]);
        LTSpace *s = [r.profile addSpace:name.length ? name : @"Imported Space"];
        if (S(space[@"theme"]).length)
            themes[s.identifier] = space[@"theme"];
        if (![r items:space[@"items"] ?: @[] space:s.identifier parent:@"" depth:0])
            break;
    }
    if (!r.problem)
        for (NSDictionary *favorite in favorites) {
            if (![favorite isKindOfClass:NSDictionary.class]) {
                [r fail:damaged];
                break;
            }
            if (![r tab:favorite kind:@"favorite" space:@"" parent:@""])
                break;
        }
    if (r.problem) {
        if (error)
            *error = LTError(r.problem);
        return nil;
    }
    r.profile.activeSpaceID = r.profile.spaces.firstObject.identifier;
    if (![r.profile validate:error])
        return nil;
    LTImportResult *result = [LTImportResult new];
    result.profile = r.profile;
    result.spaceThemes = themes;
    result.warnings =
        r.skipped == 1 ? @[ @"One tab with an empty or unsupported address was skipped." ]
        : r.skipped    ? @[ [NSString stringWithFormat:@"%lu tabs with an empty or unsupported "
                                                       @"address were skipped.",
                                                       (unsigned long)r.skipped] ]
                       : @[];
    return result;
}
@end
