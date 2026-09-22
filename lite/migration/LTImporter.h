#import "../model/LTModel.h"
NS_ASSUME_NONNULL_BEGIN
@interface LTImportResult : NSObject
@property (nonatomic) LTProfile *profile;
@property (nonatomic) NSArray<NSString *> *warnings;
@property (nonatomic, readonly) NSString *summary;
@end
@interface LTImporter : NSObject
+ (NSArray<NSURL *> *)discoverArcFiles;
+ (nullable LTImportResult *)parseArcData:(NSData *)data error:(NSError **)error;
+ (nullable LTImportResult *)parseBookmarks:(NSData *)data
                                     format:(NSString *)format
                                      error:(NSError **)error;
+ (void)merge:(LTImportResult *)result into:(LTProfile *)profile;
@end
NS_ASSUME_NONNULL_END
