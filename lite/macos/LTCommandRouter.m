#import "LTCommandRouter.h"

@implementation LTCommandRouter {
    __weak id<LTCommandTarget> _target;
}
- (instancetype)initWithTarget:(id<LTCommandTarget>)target {
    if ((self = [super init])) _target = target;
    return self;
}
- (BOOL)routeCommand:(NSString *)command item:(NSString *)identifier {
    static NSDictionary<NSString *, NSNumber *> *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = @{
            @"contentBlocking": @(LTWindowActionContentBlocking),
            @"newTab": @(LTWindowActionNewTab),
            @"address": @(LTWindowActionAddress),
            @"newWindow": @(LTWindowActionNewWindow),
            @"newPrivate": @(LTWindowActionNewPrivate),
            @"newSpace": @(LTWindowActionNewSpace),
            @"githubFolder": @(LTWindowActionGithubFolder),
            @"editGitHubFolder": @(LTWindowActionEditGitHubFolder),
            @"refreshGitHubFolder": @(LTWindowActionRefreshGitHubFolder),
            @"stopGitHubFolder": @(LTWindowActionStopGitHubFolder),
            @"taskManager": @(LTWindowActionTaskManager),
            @"shortcuts": @(LTWindowActionShortcuts),
            @"applePasswords": @(LTWindowActionApplePasswords),
            @"renameSpace": @(LTWindowActionRenameSpace),
            @"deleteSpace": @(LTWindowActionDeleteSpace),
            @"newFolder": @(LTWindowActionNewFolder),
            @"folderInside": @(LTWindowActionFolderInside),
            @"pinTab": @(LTWindowActionPinTab),
            @"rename": @(LTWindowActionRename),
            @"favorite": @(LTWindowActionFavorite),
            @"duplicate": @(LTWindowActionDuplicate),
            @"resetPinned": @(LTWindowActionResetPinned),
            @"copyURL": @(LTWindowActionCopyURL),
            @"keepAwake": @(LTWindowActionKeepAwake),
            @"moveTab": @(LTWindowActionMoveTab),
            @"moveFolder": @(LTWindowActionMoveFolder),
            @"openAll": @(LTWindowActionOpenAll),
            @"deleteNode": @(LTWindowActionDeleteNode),
            @"closeTab": @(LTWindowActionCloseTab),
            @"reopenTab": @(LTWindowActionReopenTab),
            @"reopenWindow": @(LTWindowActionReopenWindow),
            @"splitRight": @(LTWindowActionSplitRight),
            @"splitDown": @(LTWindowActionSplitDown),
            @"splitTab": @(LTWindowActionSplitTab),
            @"closeSplit": @(LTWindowActionCloseSplit),
            @"swapSplit": @(LTWindowActionSwapSplit),
            @"focusSplit": @(LTWindowActionFocusSplit),
            @"nextSpace": @(LTWindowActionNextSpace),
            @"previousSpace": @(LTWindowActionPreviousSpace),
            @"nextTab": @(LTWindowActionNextTab),
            @"previousTab": @(LTWindowActionPreviousTab),
            @"toggleSidebar": @(LTWindowActionToggleSidebar),
            @"downloads": @(LTWindowActionDownloads),
            @"history": @(LTWindowActionHistory),
            @"settings": @(LTWindowActionSettings),
            @"importArc": @(LTWindowActionImportArc),
            @"importBookmarks": @(LTWindowActionImportBookmarks),
            @"exportBookmarks": @(LTWindowActionExportBookmarks),
            @"exportOrganization": @(LTWindowActionExportOrganization),
            @"saveLogin": @(LTWindowActionSaveLogin),
            @"fillLogin": @(LTWindowActionFillLogin),
            @"passwords": @(LTWindowActionPasswords),
            @"googlePasswords": @(LTWindowActionGooglePasswords),
            @"clearData": @(LTWindowActionClearData),
            @"extensions": @(LTWindowActionExtensions),
            @"defaultBrowser": @(LTWindowActionDefaultBrowser),
            @"fullScreen": @(LTWindowActionFullScreen),
            @"back": @(LTWindowActionBack),
            @"forward": @(LTWindowActionForward),
            @"reload": @(LTWindowActionReload),
            @"find": @(LTWindowActionFind),
            @"print": @(LTWindowActionPrint),
            @"save": @(LTWindowActionSave),
            @"zoomIn": @(LTWindowActionZoomIn),
            @"zoomOut": @(LTWindowActionZoomOut),
            @"zoomReset": @(LTWindowActionZoomReset),
            @"devTools": @(LTWindowActionDevTools),
            @"pip": @(LTWindowActionPip),
        };
    });
    NSNumber *action = command.length ? actions[command] : nil;
    id<LTCommandTarget> target = _target;
    if (!action || !target) return NO;
    [target performWindowAction:(LTWindowAction)action.unsignedIntegerValue item:identifier];
    return YES;
}
@end
