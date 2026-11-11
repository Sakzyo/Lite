#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Parses one supported ## or #@# rule. The caller applies list and line size limits.
// Returns host (empty for generic), selectors (split only at selector-list commas),
// and exception, or a refusal reason.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable LTParseCustomCosmeticFilter(
    NSString *line, NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
