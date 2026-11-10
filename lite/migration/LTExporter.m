#import "LTExporter.h"

NSString *const LTOrganizationFormat = @"lite-organization";
const NSInteger LTOrganizationVersion = 1;

static NSString *Escape(NSString *text) {
    NSMutableString *s = [text mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}
// The address a saved tab returns to.
static NSString *SavedURL(LTNode *node) {
    return node.pinnedURL.length ? node.pinnedURL : node.url;
}
static NSArray<LTNode *> *Favorites(LTProfile *profile) {
    NSMutableArray *favorites = [NSMutableArray new];
    for (LTNode *n in [profile childrenInSpace:@""][@""])
        if ([n.kind isEqual:@"favorite"])
            [favorites addObject:n];
    return favorites;
}
// A Space's chosen color, or nil when it uses the automatic one.
static NSString *Theme(LTProfile *profile, NSString *space) {
    NSDictionary *themes = profile.settings[@"spaceThemes"];
    NSString *theme = [themes isKindOfClass:NSDictionary.class] ? themes[space] : nil;
    return [theme isKindOfClass:NSString.class] && theme.length ? theme : nil;
}

static void HTMLLink(NSMutableString *out, LTNode *node, NSString *indent) {
    [out appendFormat:@"%@<DT><A HREF=\"%@\">%@</A>\n", indent, Escape(SavedURL(node)),
                      Escape(node.displayTitle)];
}
static void HTMLItems(NSMutableString *out, NSDictionary<NSString *, NSArray<LTNode *> *> *children,
                      NSString *parent, NSString *indent) {
    for (LTNode *n in children[parent]) {
        if ([n.kind isEqual:@"folder"]) {
            [out appendFormat:@"%@<DT><H3>%@</H3>\n%@<DL><p>\n", indent, Escape(n.displayTitle),
                              indent];
            HTMLItems(out, children, n.identifier, [indent stringByAppendingString:@"    "]);
            [out appendFormat:@"%@</DL><p>\n", indent];
        } else if ([n.kind isEqual:@"pinned"])
            HTMLLink(out, n, indent);
    }
}

static NSArray *JSONItems(NSDictionary<NSString *, NSArray<LTNode *> *> *children, NSString *parent) {
    NSMutableArray *items = [NSMutableArray new];
    for (LTNode *n in children[parent]) {
        if ([n.kind isEqual:@"folder"])
            [items addObject:@{
                @"type" : @"folder",
                @"title" : n.displayTitle,
                @"open" : @(n.expanded),
                @"items" : JSONItems(children, n.identifier)
            }];
        else if ([n.kind isEqual:@"pinned"]) {
            NSMutableDictionary *tab =
                [@{@"type" : @"tab", @"title" : n.title, @"url" : SavedURL(n)} mutableCopy];
            if (n.customTitle.length)
                tab[@"customTitle"] = n.customTitle;
            [items addObject:tab];
        }
    }
    return items;
}

@implementation LTExporter
+ (NSData *)bookmarksHTML:(LTProfile *)profile {
    NSMutableString *out = [NSMutableString stringWithString:
        @"<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
        @"<!-- This is an automatically generated file.\n"
        @"     It will be read and overwritten.\n"
        @"     DO NOT EDIT! -->\n"
        @"<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
        @"<TITLE>Bookmarks</TITLE>\n"
        @"<H1>Bookmarks</H1>\n"
        @"<DL><p>\n"];
    NSArray<LTNode *> *favorites = Favorites(profile);
    if (favorites.count) {
        [out appendString:@"    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Favorites</H3>\n    <DL><p>\n"];
        for (LTNode *n in favorites)
            HTMLLink(out, n, @"        ");
        [out appendString:@"    </DL><p>\n"];
    }
    for (LTSpace *space in profile.spaces) {
        [out appendFormat:@"    <DT><H3>%@</H3>\n    <DL><p>\n", Escape(space.name)];
        HTMLItems(out, [profile childrenInSpace:space.identifier], @"", @"        ");
        [out appendString:@"    </DL><p>\n"];
    }
    [out appendString:@"</DL><p>\n"];
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}
+ (NSData *)organizationJSON:(LTProfile *)profile date:(NSDate *)date {
    NSMutableArray *spaces = [NSMutableArray new], *favorites = [NSMutableArray new];
    for (LTSpace *space in profile.spaces) {
        NSMutableDictionary *s = [@{
            @"name" : space.name,
            @"items" : JSONItems([profile childrenInSpace:space.identifier], @"")
        } mutableCopy];
        NSString *theme = Theme(profile, space.identifier);
        if (theme)
            s[@"theme"] = theme;
        [spaces addObject:s];
    }
    for (LTNode *n in Favorites(profile)) {
        NSMutableDictionary *f = [@{@"title" : n.title, @"url" : SavedURL(n)} mutableCopy];
        if (n.customTitle.length)
            f[@"customTitle"] = n.customTitle;
        [favorites addObject:f];
    }
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSDictionary *file = @{
        @"format" : LTOrganizationFormat,
        @"version" : @(LTOrganizationVersion),
        @"exported" : [iso stringFromDate:date],
        @"favorites" : favorites,
        @"spaces" : spaces
    };
    return [NSJSONSerialization
        dataWithJSONObject:file
                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys |
                           NSJSONWritingWithoutEscapingSlashes
                     error:nil];
}
@end
