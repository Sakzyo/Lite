#import "LTModel.h"
FOUNDATION_EXPORT NSInteger LTFuzzyScore(NSString *query, NSString *text);
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTCommandResults(NSString *query, LTProfile *profile,
                                                            NSArray<NSDictionary *> *history,
                                                            NSSet<NSString *> *openIDs);
