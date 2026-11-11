#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Window operations are typed; only the router interprets command strings.
typedef NS_ENUM(NSUInteger, LTWindowAction) {
    LTWindowActionContentBlocking,
    LTWindowActionNewTab,
    LTWindowActionAddress,
    LTWindowActionNewWindow,
    LTWindowActionNewPrivate,
    LTWindowActionNewSpace,
    LTWindowActionGithubFolder,
    LTWindowActionEditGitHubFolder,
    LTWindowActionRefreshGitHubFolder,
    LTWindowActionStopGitHubFolder,
    LTWindowActionTaskManager,
    LTWindowActionShortcuts,
    LTWindowActionApplePasswords,
    LTWindowActionRenameSpace,
    LTWindowActionDeleteSpace,
    LTWindowActionNewFolder,
    LTWindowActionFolderInside,
    LTWindowActionPinTab,
    LTWindowActionRename,
    LTWindowActionFavorite,
    LTWindowActionDuplicate,
    LTWindowActionResetPinned,
    LTWindowActionCopyURL,
    LTWindowActionKeepAwake,
    LTWindowActionMoveTab,
    LTWindowActionMoveFolder,
    LTWindowActionOpenAll,
    LTWindowActionDeleteNode,
    LTWindowActionCloseTab,
    LTWindowActionReopenTab,
    LTWindowActionReopenWindow,
    LTWindowActionSplitRight,
    LTWindowActionSplitDown,
    LTWindowActionSplitTab,
    LTWindowActionCloseSplit,
    LTWindowActionSwapSplit,
    LTWindowActionFocusSplit,
    LTWindowActionNextSpace,
    LTWindowActionPreviousSpace,
    LTWindowActionNextTab,
    LTWindowActionPreviousTab,
    LTWindowActionToggleSidebar,
    LTWindowActionDownloads,
    LTWindowActionHistory,
    LTWindowActionSettings,
    LTWindowActionImportArc,
    LTWindowActionImportBookmarks,
    LTWindowActionExportBookmarks,
    LTWindowActionExportOrganization,
    LTWindowActionSaveLogin,
    LTWindowActionFillLogin,
    LTWindowActionPasswords,
    LTWindowActionGooglePasswords,
    LTWindowActionClearData,
    LTWindowActionExtensions,
    LTWindowActionDefaultBrowser,
    LTWindowActionFullScreen,
    LTWindowActionBack,
    LTWindowActionForward,
    LTWindowActionReload,
    LTWindowActionFind,
    LTWindowActionPrint,
    LTWindowActionSave,
    LTWindowActionZoomIn,
    LTWindowActionZoomOut,
    LTWindowActionZoomReset,
    LTWindowActionDevTools,
    LTWindowActionPip,
};

@protocol LTCommandTarget <NSObject>
- (void)performWindowAction:(LTWindowAction)action item:(nullable NSString *)identifier;
@end

@interface LTCommandRouter : NSObject
// The target is weak: a window can own its router without a retain cycle.
- (instancetype)initWithTarget:(id<LTCommandTarget>)target;
// Returns NO for an unknown command or a target that has gone away. Items pass through unchanged.
- (BOOL)routeCommand:(nullable NSString *)command item:(nullable NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
