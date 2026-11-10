#import "../model/LTModel.h"
NS_ASSUME_NONNULL_BEGIN
// The `format` value that marks a Lite organization file.
FOUNDATION_EXPORT NSString *const LTOrganizationFormat;
// The newest organization file version this build writes and reads.
FOUNDATION_EXPORT const NSInteger LTOrganizationVersion;

// Writes the sidebar out of Lite. Both formats leave out temporary tabs, which are open pages rather
// than saved ones, and neither carries history, window state, favicons or settings beyond Space
// colors. A pinned tab is written with the address it was pinned at, not where it has since gone.
@interface LTExporter : NSObject
// A Netscape bookmarks file, which Safari, Chrome, Firefox and Lite import: a Favorites folder marked
// as the bookmarks bar, then a folder for each Space holding its folders and pinned tabs in sidebar
// order. Each tab is written under the name the sidebar shows.
+ (NSData *)bookmarksHTML:(LTProfile *)profile;
// A Lite organization file (JSON), which Lite's Import Bookmarks reads back: Spaces in order with any
// color chosen for them, folders with whether they are open, pinned tabs with their page title and
// any name given in Lite, and Favorites in order.
+ (NSData *)organizationJSON:(LTProfile *)profile date:(NSDate *)date;
@end
NS_ASSUME_NONNULL_END
