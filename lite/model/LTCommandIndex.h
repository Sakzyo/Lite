#import "LTModel.h"
FOUNDATION_EXPORT NSInteger LTFuzzyScore(NSString *query, NSString *text);
// The Command Bar's rows for `query`, best first. `suggestions` are the search engine's suggestions
// for it, or nil; they follow the row that searches for the text as typed, so they never change
// what Return does.
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTCommandResults(NSString *query, LTProfile *profile,
                                                            NSArray<NSDictionary *> *history,
                                                            NSSet<NSString *> *openIDs,
                                                            NSArray<NSString *> *suggestions);
