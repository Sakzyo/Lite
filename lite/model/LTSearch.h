#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Search engines and Command Bar suggestions.
//
// An engine is a dictionary: `name`, `url` (a search address in which "%s" stands for the query)
// and optionally `suggest` (an address that answers with OpenSearch suggestions JSON, also with
// "%s"). The profile's settings hold `search`, the selected engine's name; `searchEngines`, the
// user's own engines; and `searchSuggestions`, which is off unless the user turns it on.
FOUNDATION_EXPORT NSString *const LTDefaultSearchEngine;
FOUNDATION_EXPORT const NSUInteger LTCustomSearchEngineLimit;
// How many suggestions the Command Bar lists.
FOUNDATION_EXPORT const NSUInteger LTSearchSuggestionLimit;

FOUNDATION_EXPORT NSArray<NSDictionary *> *LTBuiltInSearchEngines(void);
// The built-in engines, then the user's own in the order they were added.
FOUNDATION_EXPORT NSArray<NSDictionary *> *LTSearchEngines(NSDictionary *_Nullable settings);
// The engine `search` names, or the default when it names none.
FOUNDATION_EXPORT NSDictionary *LTSelectedSearchEngine(NSDictionary *_Nullable settings);
// Checks the user's entry and returns the engine to store. `existing` is the current
// `searchEngines`. "{searchTerms}" is accepted for "%s". A search address is http or https; a
// suggestions address is https, or http on this Mac only, because it receives text as it is typed.
// In either, the query may not choose the host.
FOUNDATION_EXPORT NSDictionary *_Nullable LTCustomSearchEngine(NSString *name, NSString *url,
                                                               NSString *_Nullable suggest,
                                                               NSArray *_Nullable existing,
                                                               NSError **error);
// For the profile validator: `search`, `searchEngines` and `searchSuggestions` are well formed.
FOUNDATION_EXPORT BOOL LTValidSearchSettings(NSDictionary *settings);
FOUNDATION_EXPORT NSString *LTSearchURL(NSString *query, NSDictionary *_Nullable settings);
// Where to ask for suggestions for `query`, or nil when nothing may be sent: suggestions are off,
// the engine has no suggestions address, or the text is empty, long, or an address rather than a
// search.
FOUNDATION_EXPORT NSURL *_Nullable LTSearchSuggestionURL(NSString *query,
                                                         NSDictionary *_Nullable settings);
// Reads an OpenSearch suggestions response, `["query", ["one", "two"]]`. `encoding` is the
// response's charset when it names one. Returns at most LTSearchSuggestionLimit single-line
// suggestions, without `query` itself or repeats; anything else gives an empty list.
FOUNDATION_EXPORT NSArray<NSString *> *LTParseSearchSuggestions(NSData *data,
                                                                NSString *_Nullable encoding,
                                                                NSString *query);

// Fetches suggestions for a window's Command Bar. Use it from the main thread. Requests carry no
// cookies, are not cached on disk, and are not followed through redirects. Answers are remembered
// in memory until -forget. One object serves a window for as long as it is open, so that a
// connection to the engine is reused instead of opened again each time the Command Bar appears.
@interface LTSearchSuggestions : NSObject
// `delay` is how long typing must pause before a request is sent.
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration
                                delay:(NSTimeInterval)delay NS_DESIGNATED_INITIALIZER;
// Drops any earlier request, then asks for `query`. Returns NO, and never calls `completion`, when
// LTSearchSuggestionURL allows nothing to be sent. Otherwise `completion` runs once on the main
// thread unless a later call, -cancel or -forget comes first: at once for a remembered answer, and
// with an empty list when the request fails.
- (BOOL)suggest:(NSString *)query
       settings:(NSDictionary *_Nullable)settings
     completion:(void (^)(NSArray<NSString *> *suggestions))completion;
- (void)cancel;
// Cancels, and drops the remembered answers. For when the Command Bar closes.
- (void)forget;
@end
NS_ASSUME_NONNULL_END
