// Routing tests run with a recording target, without AppKit, a window or the CEF runtime.
#import "../macos/LTCommandRouter.h"
#import "../model/LTCommandIndex.h"

static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

@interface LTRecordingCommandTarget : NSObject <LTCommandTarget>
@property (nonatomic) NSUInteger calls;
@property (nonatomic) LTWindowAction action;
@property (nonatomic, strong) NSString *item;
@end
@implementation LTRecordingCommandTarget
- (void)performWindowAction:(LTWindowAction)action item:(NSString *)identifier {
    self.calls++;
    self.action = action;
    self.item = identifier;
}
@end

// Independent expectations make a wrong mapping fail even when both command names are supported.
static NSDictionary<NSString *, NSNumber *> *ExpectedActions(void) {
    return @{
        @"contentBlocking": @(LTWindowActionContentBlocking),
        @"newTab": @(LTWindowActionNewTab), @"address": @(LTWindowActionAddress),
        @"newWindow": @(LTWindowActionNewWindow), @"newPrivate": @(LTWindowActionNewPrivate),
        @"newSpace": @(LTWindowActionNewSpace), @"githubFolder": @(LTWindowActionGithubFolder),
        @"editGitHubFolder": @(LTWindowActionEditGitHubFolder),
        @"refreshGitHubFolder": @(LTWindowActionRefreshGitHubFolder),
        @"stopGitHubFolder": @(LTWindowActionStopGitHubFolder),
        @"taskManager": @(LTWindowActionTaskManager), @"shortcuts": @(LTWindowActionShortcuts),
        @"applePasswords": @(LTWindowActionApplePasswords), @"renameSpace": @(LTWindowActionRenameSpace),
        @"deleteSpace": @(LTWindowActionDeleteSpace), @"newFolder": @(LTWindowActionNewFolder),
        @"folderInside": @(LTWindowActionFolderInside), @"pinTab": @(LTWindowActionPinTab),
        @"rename": @(LTWindowActionRename), @"favorite": @(LTWindowActionFavorite),
        @"duplicate": @(LTWindowActionDuplicate), @"resetPinned": @(LTWindowActionResetPinned),
        @"copyURL": @(LTWindowActionCopyURL), @"keepAwake": @(LTWindowActionKeepAwake),
        @"moveTab": @(LTWindowActionMoveTab), @"moveFolder": @(LTWindowActionMoveFolder),
        @"openAll": @(LTWindowActionOpenAll), @"deleteNode": @(LTWindowActionDeleteNode),
        @"closeTab": @(LTWindowActionCloseTab), @"reopenTab": @(LTWindowActionReopenTab),
        @"reopenWindow": @(LTWindowActionReopenWindow), @"splitRight": @(LTWindowActionSplitRight),
        @"splitDown": @(LTWindowActionSplitDown), @"splitTab": @(LTWindowActionSplitTab),
        @"closeSplit": @(LTWindowActionCloseSplit), @"swapSplit": @(LTWindowActionSwapSplit),
        @"focusSplit": @(LTWindowActionFocusSplit), @"nextSpace": @(LTWindowActionNextSpace),
        @"previousSpace": @(LTWindowActionPreviousSpace), @"nextTab": @(LTWindowActionNextTab),
        @"previousTab": @(LTWindowActionPreviousTab), @"toggleSidebar": @(LTWindowActionToggleSidebar),
        @"downloads": @(LTWindowActionDownloads), @"history": @(LTWindowActionHistory),
        @"settings": @(LTWindowActionSettings), @"importArc": @(LTWindowActionImportArc),
        @"importBookmarks": @(LTWindowActionImportBookmarks),
        @"exportBookmarks": @(LTWindowActionExportBookmarks),
        @"exportOrganization": @(LTWindowActionExportOrganization),
        @"saveLogin": @(LTWindowActionSaveLogin), @"fillLogin": @(LTWindowActionFillLogin),
        @"passwords": @(LTWindowActionPasswords), @"googlePasswords": @(LTWindowActionGooglePasswords),
        @"clearData": @(LTWindowActionClearData), @"extensions": @(LTWindowActionExtensions),
        @"defaultBrowser": @(LTWindowActionDefaultBrowser), @"fullScreen": @(LTWindowActionFullScreen),
        @"back": @(LTWindowActionBack), @"forward": @(LTWindowActionForward),
        @"reload": @(LTWindowActionReload), @"find": @(LTWindowActionFind),
        @"print": @(LTWindowActionPrint), @"save": @(LTWindowActionSave),
        @"zoomIn": @(LTWindowActionZoomIn), @"zoomOut": @(LTWindowActionZoomOut),
        @"zoomReset": @(LTWindowActionZoomReset), @"devTools": @(LTWindowActionDevTools),
        @"pip": @(LTWindowActionPip)
    };
}

static void TestRouting(void) {
    LTRecordingCommandTarget *target = [LTRecordingCommandTarget new];
    LTCommandRouter *router = [[LTCommandRouter alloc] initWithTarget:target];
    NSDictionary *expected = ExpectedActions();
    CHECK(expected.count == 68, "all 68 window commands have independent expectations");
    for (NSString *command in [expected.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSUInteger before = target.calls;
        NSString *item = [@"clicked-item/" stringByAppendingString:command];
        BOOL routed = [router routeCommand:command item:item];
        CHECK(routed && target.calls == before + 1 && target.action == [expected[command] unsignedIntegerValue] &&
                  target.item == item, command.UTF8String);
    }
    NSUInteger before = target.calls;
    CHECK(![router routeCommand:@"notACommand" item:@"tab"] &&
              ![router routeCommand:@"Reload" item:@"tab"] &&
              ![router routeCommand:@"reload " item:@"tab"] &&
              ![router routeCommand:@"" item:@"tab"] &&
              ![router routeCommand:nil item:@"tab"] && target.calls == before,
          "unknown, differently cased, padded, empty and nil commands dispatch nothing");
    NSArray *items = @[@"clicked-tab-not-focused", @"folder-id", @"space-id", @""];
    for (NSString *item in items) {
        CHECK([router routeCommand:@"rename" item:item] && target.item == item,
              "the caller's item ID passes through without selection or normalization");
    }
    CHECK([router routeCommand:@"newTab" item:nil] && target.item == nil,
          "nil item passes through unchanged");
    __weak LTRecordingCommandTarget *weakTarget;
    LTCommandRouter *orphan;
    @autoreleasepool {
        LTRecordingCommandTarget *temporary = [LTRecordingCommandTarget new];
        weakTarget = temporary;
        orphan = [[LTCommandRouter alloc] initWithTarget:temporary];
    }
    CHECK(!weakTarget && ![orphan routeCommand:@"reload" item:@"tab"],
          "a router does not retain a closed window and rejects dispatch after its target dies");
}

static NSString *ReadSource(NSString *root, NSString *path) {
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:path]
                                                encoding:NSUTF8StringEncoding error:&error];
    CHECK(source != nil, path.UTF8String);
    return source ?: @"";
}
static NSString *Between(NSString *source, NSString *start, NSString *end) {
    NSRange first = [source rangeOfString:start];
    CHECK(first.location != NSNotFound, start.UTF8String);
    if (first.location == NSNotFound) return @"";
    NSString *tail = [source substringFromIndex:NSMaxRange(first)];
    NSRange last = [tail rangeOfString:end];
    CHECK(last.location != NSNotFound, end.UTF8String);
    return last.location == NSNotFound ? @"" : [tail substringToIndex:last.location];
}

// Menus/settings are currently inline tables in AppKit/CEF source. Read their actual rows instead
// of maintaining another command list. This small reader only needs Objective-C array literals:
// skip quoted text and nested brackets, then take the literal string after the first row comma.
// That also handles the sidebar's conditional Pin/Unpin title. Counts below catch parser drift.
static NSArray<NSDictionary *> *CommandRows(NSString *source) {
    NSMutableArray *rows = [NSMutableArray new];
    NSRegularExpression *literal = [NSRegularExpression regularExpressionWithPattern:@"^\\s*@\"([^\"\\n]*)\"" options:0 error:nil];
    for (NSUInteger start = 0; start + 1 < source.length; start++) {
        if ([source characterAtIndex:start] != '@' || [source characterAtIndex:start + 1] != '[') continue;
        NSInteger depth = 1;
        BOOL quoted = NO, escaped = NO;
        for (NSUInteger i = start + 2; i < source.length && depth; i++) {
            unichar c = [source characterAtIndex:i];
            if (quoted) {
                if (escaped) escaped = NO;
                else if (c == '\\') escaped = YES;
                else if (c == '"') quoted = NO;
                continue;
            }
            if (c == '"') { quoted = YES; continue; }
            if (c == '[') depth++;
            else if (c == ']') depth--;
            else if (c == ',' && depth == 1) {
                NSString *value = [source substringFromIndex:i + 1];
                NSTextCheckingResult *match = [literal firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
                if (match && [match rangeAtIndex:1].length) {
                    NSString *title = [source substringWithRange:NSMakeRange(start + 2, i - start - 2)];
                    NSTextCheckingResult *label = [literal firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
                    [rows addObject:@{@"command": [value substringWithRange:[match rangeAtIndex:1]],
                                      @"title": label ? [title substringWithRange:[label rangeAtIndex:1]] : @""}];
                }
                break;
            }
        }
    }
    return rows;
}
static void CheckRows(NSArray<NSDictionary *> *rows, NSUInteger minimum, LTCommandRouter *router,
                      NSSet<NSString *> *excluded, NSMutableSet<NSString *> *emitted, const char *label) {
    CHECK(rows.count >= minimum, label);
    for (NSDictionary *row in rows) {
        NSString *command = row[@"command"];
        if ([excluded containsObject:command]) continue;
        [emitted addObject:command];
        CHECK([router routeCommand:command item:@"emitter-item"], command.UTF8String);
    }
}

static void TestEmitters(NSString *root) {
    LTRecordingCommandTarget *target = [LTRecordingCommandTarget new];
    LTCommandRouter *router = [[LTCommandRouter alloc] initWithTarget:target];
    NSMutableSet *emitted = [NSMutableSet new];
    NSString *index = ReadSource(root, @"lite/model/LTCommandIndex.m");
    NSArray *commands = CommandRows(Between(index, @"NSArray *commands = @[", @"for (NSArray *c in commands)"));
    CheckRows(commands, 34, router, nil, emitted, "Command Bar catalog includes its rows beyond the 30-result limit");
    LTProfile *profile = LTProfile.fresh;
    for (NSDictionary *command in commands) {
        BOOL found = NO;
        for (NSDictionary *result in LTCommandResults(command[@"title"], profile, @[], [NSSet set], nil)) {
            if ([result[@"type"] isEqual:@"command"] && [result[@"value"] isEqual:command[@"command"]])
                found = [router routeCommand:result[@"value"] item:@"focused-tab"];
        }
        CHECK(found, [command[@"title"] UTF8String]);
    }
    NSString *main = ReadSource(root, @"lite/macos/main.mm");
    // Native responder/app actions never reach LTWindow. New-window actions are still covered:
    // menus handle them directly, while the Command Bar reaches them through the window router.
    NSSet *appActions = [NSSet setWithArray:@[@"about", @"hide", @"quit", @"checkUpdates", @"undo:",
        @"redo:", @"cut:", @"copy:", @"paste:", @"selectAll:", @"performMiniaturize:"]];
    CheckRows(CommandRows(Between(main, @"NSArray *menus = @[", @"for (NSArray *spec in menus)")),
              61, router, appActions, emitted, "every native menu and shortcut command is accounted for");
    NSString *shortcuts = ReadSource(root, @"lite/macos/LTShortcuts.m");
    NSString *collect = Between(shortcuts, @"- (void)collect:(NSMenu *)menu {", @"- (void)apply {");
    CHECK([collect containsString:@"[self collect:item.submenu]"] &&
              [collect containsString:@"item.representedObject"] && [collect containsString:@"[_items addObject:item]"],
          "shortcuts inherit the native menu's command vocabulary");
    NSString *panel = ReadSource(root, @"lite/macos/LTCommandPanel.m");
    CHECK([panel containsString:@"NSDictionary *result = _results[row]"] &&
              [panel containsString:@"_selected(result)"], "Command Bar forwards the selected index result");
    NSString *sidebar = ReadSource(root, @"lite/macos/LTSidebar.m");
    CheckRows(CommandRows(Between(sidebar, @"- (void)menuNeedsUpdate:", @"- (void)contextAction:")),
              20, router, nil, emitted, "folder, tab and GitHub sidebar actions all route");
    CheckRows(CommandRows(Between(sidebar, @"- (void)spaceMenu:", @"if (!_store.privateMode)")),
              3, router, nil, emitted, "Space context actions all route");
    CheckRows(CommandRows(Between(sidebar, @"- (void)libraryMenu:", @"[m popUpMenuPositioningItem:")),
              3, router, nil, emitted, "sidebar Library actions all route");
    NSString *settings = ReadSource(root, @"lite/macos/LTLibraryPanel.m");
    CheckRows(CommandRows(Between(settings, @"NSArray *actions = @[", @"for (NSArray *a in actions)")),
              12, router, nil, emitted, "Settings actions all route");
    CHECK([emitted isEqualToSet:[NSSet setWithArray:ExpectedActions().allKeys]],
          "the emitter union covers exactly the tested window command vocabulary");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: LiteCommandRouterTests <source root>\n"); return 2; }
        TestRouting();
        TestEmitters([NSString stringWithUTF8String:argv[1]]);
        printf("%d passed, %d failed\n", passed, failed);
    }
    return failed ? 1 : 0;
}
