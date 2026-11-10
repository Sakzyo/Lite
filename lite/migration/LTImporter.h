#import "../model/LTModel.h"
NS_ASSUME_NONNULL_BEGIN
@interface LTImportResult : NSObject
@property (nonatomic) LTProfile *profile;
@property (nonatomic) NSArray<NSString *> *warnings;
// Colors chosen for imported Spaces, keyed by the new Space identifier.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *spaceThemes;
@property (nonatomic, readonly) NSString *summary;
@end
@interface LTImporter : NSObject
+ (NSArray<NSURL *> *)discoverArcFiles;
+ (nullable LTImportResult *)parseArcData:(NSData *)data error:(NSError **)error;
// `format` is "html", "plist" or "json". JSON is a Chromium Bookmarks file, or a Lite organization
// file when it says so.
+ (nullable LTImportResult *)parseBookmarks:(NSData *)data
                                     format:(NSString *)format
                                      error:(NSError **)error;
// A file written by LTExporter's organizationJSON. Every item gets a new identifier. Tabs whose
// address Lite cannot open are skipped with a warning; anything else malformed imports nothing.
+ (nullable LTImportResult *)parseOrganization:(NSData *)data error:(NSError **)error;
+ (void)merge:(LTImportResult *)result into:(LTProfile *)profile;
@end
NS_ASSUME_NONNULL_END
