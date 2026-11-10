#import "LTSearch.h"
#import "LTModel.h"

NSString *const LTDefaultSearchEngine = @"DuckDuckGo";
const NSUInteger LTCustomSearchEngineLimit = 32;
const NSUInteger LTSearchSuggestionLimit = 4;
static const NSUInteger MaxNameLength = 64, MaxTemplateLength = 2048, MaxQueryLength = 256,
                        MaxSuggestionLength = 200, MaxResponseBytes = 64 * 1024, MaxAnswers = 64;

NSArray<NSDictionary *> *LTBuiltInSearchEngines(void) {
    static NSArray *engines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableArray *list = [NSMutableArray new];
      for (NSArray *e in @[
               @[ @"DuckDuckGo", @"https://duckduckgo.com/?q=%s", @"https://duckduckgo.com/ac/?q=%s&type=list" ],
               @[ @"Google", @"https://www.google.com/search?q=%s",
                  @"https://www.google.com/complete/search?client=firefox&q=%s" ],
               @[ @"Bing", @"https://www.bing.com/search?q=%s", @"https://www.bing.com/osjson.aspx?query=%s" ],
               @[ @"Brave Search", @"https://search.brave.com/search?q=%s",
                  @"https://search.brave.com/api/suggest?q=%s" ],
               @[ @"Ecosia", @"https://www.ecosia.org/search?q=%s",
                  @"https://ac.ecosia.org/autocomplete?q=%s&type=list" ],
               @[ @"Kagi", @"https://kagi.com/search?q=%s", @"https://kagi.com/api/autosuggest?q=%s" ],
               @[ @"Startpage", @"https://www.startpage.com/sp/search?query=%s",
                  @"https://www.startpage.com/osuggestions?q=%s" ]
           ])
          [list addObject:@{@"name" : e[0], @"url" : e[1], @"suggest" : e[2]}];
      engines = list;
    });
    return engines;
}
static NSString *Trim(NSString *text) {
    return [text isKindOfClass:NSString.class]
               ? [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
               : @"";
}
// Puts the query where "%s" is. Only unreserved characters stay as typed, so a query is one path
// segment or one query value wherever the address uses it, and "c++" stays "c++".
static NSString *Fill(NSString *address, NSString *query) {
    static NSCharacterSet *unreserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      unreserved = [NSCharacterSet
          characterSetWithCharactersInString:
              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:unreserved] ?: @"";
    return [address stringByReplacingOccurrencesOfString:@"%s" withString:encoded];
}
static BOOL OneLine(NSString *text) {
    return [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
           [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
// What is wrong with a search or suggestions address, or nil.
static NSString *AddressProblem(NSString *address, BOOL suggestions) {
    NSString *what = suggestions ? @"The suggestions address" : @"The search address";
    if (!address.length || address.length > MaxTemplateLength)
        return [what stringByAppendingString:@" is missing or too long."];
    if (!OneLine(address) ||
        [address rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound)
        return [what stringByAppendingString:@" cannot contain spaces."];
    if (![address containsString:@"%s"])
        return [what stringByAppendingString:@" needs %s where the search text goes."];
    NSURLComponents *a = [NSURLComponents componentsWithString:Fill(address, @"a")],
                    *b = [NSURLComponents componentsWithString:Fill(address, @"b")];
    NSString *scheme = a.scheme.lowercaseString;
    if (!a || !b || !a.host.length || !([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) ||
        !LTValidURL(Fill(address, @"lite search")))
        return [what stringByAppendingString:@" must be an http or https web address."];
    if (![a.host isEqual:b.host] || ![a.scheme isEqual:b.scheme] ||
        !(a.port == b.port || [a.port isEqual:b.port]))
        return [what stringByAppendingString:@" cannot use %s in the site’s name."];
    BOOL local = [@[ @"localhost", @"127.0.0.1", @"::1", @"[::1]" ] containsObject:a.host.lowercaseString];
    if (suggestions && ![scheme isEqual:@"https"] && !local)
        return @"The suggestions address must use https, because it receives text as you type.";
    return nil;
}
static NSString *NameProblem(NSString *name, NSArray *existing) {
    if (!name.length || name.length > MaxNameLength || !OneLine(name))
        return @"Give the search engine a name of up to 64 characters.";
    NSMutableArray *taken = [[LTBuiltInSearchEngines() valueForKey:@"name"] mutableCopy];
    for (id engine in existing)
        if ([engine isKindOfClass:NSDictionary.class] && [engine[@"name"] isKindOfClass:NSString.class])
            [taken addObject:engine[@"name"]];
    for (NSString *other in taken)
        if ([other caseInsensitiveCompare:name] == NSOrderedSame)
            return [NSString stringWithFormat:@"There is already a search engine named “%@”.", other];
    return nil;
}
NSDictionary *LTCustomSearchEngine(NSString *name, NSString *url, NSString *suggest, NSArray *existing,
                                   NSError **error) {
    NSString * (^address)(NSString *) = ^(NSString *text) {
      return [Trim(text) stringByReplacingOccurrencesOfString:@"{searchTerms}" withString:@"%s"];
    };
    name = Trim(name);
    url = address(url);
    suggest = address(suggest);
    NSString *problem =
        existing.count >= LTCustomSearchEngineLimit
            ? [NSString stringWithFormat:@"Lite keeps up to %lu search engines of your own. Remove one first.",
                                         (unsigned long)LTCustomSearchEngineLimit]
            : NameProblem(name, existing) ?: AddressProblem(url, NO)
                                          ?: (suggest.length ? AddressProblem(suggest, YES) : nil);
    if (problem) {
        if (error)
            *error = LTError(problem);
        return nil;
    }
    return suggest.length ? @{@"name" : name, @"url" : url, @"suggest" : suggest}
                          : @{@"name" : name, @"url" : url};
}
BOOL LTValidSearchSettings(NSDictionary *settings) {
    id suggestions = settings[@"searchSuggestions"];
    if (suggestions &&
        !([suggestions isKindOfClass:NSNumber.class] && ([suggestions isEqual:@0] || [suggestions isEqual:@1])))
        return NO;
    NSArray *custom = settings[@"searchEngines"];
    if (custom) {
        if (![custom isKindOfClass:NSArray.class] || custom.count > LTCustomSearchEngineLimit)
            return NO;
        // Each engine must be exactly what LTCustomSearchEngine would store.
        NSMutableArray *earlier = [NSMutableArray new];
        for (NSDictionary *engine in custom) {
            if (![engine isKindOfClass:NSDictionary.class] || ![engine[@"name"] isKindOfClass:NSString.class] ||
                ![engine[@"url"] isKindOfClass:NSString.class] ||
                (engine[@"suggest"] && ![engine[@"suggest"] isKindOfClass:NSString.class]) ||
                ![LTCustomSearchEngine(engine[@"name"], engine[@"url"], engine[@"suggest"], earlier, NULL)
                    isEqual:engine])
                return NO;
            [earlier addObject:engine];
        }
    }
    id search = settings[@"search"];
    return !search || ([search isKindOfClass:NSString.class] &&
                       [[LTSearchEngines(settings) valueForKey:@"name"] containsObject:search]);
}
NSArray<NSDictionary *> *LTSearchEngines(NSDictionary *settings) {
    NSArray *custom = settings[@"searchEngines"];
    if (![custom isKindOfClass:NSArray.class] || !custom.count)
        return LTBuiltInSearchEngines();
    NSMutableArray *engines = [LTBuiltInSearchEngines() mutableCopy];
    for (NSDictionary *engine in custom)
        if ([engine isKindOfClass:NSDictionary.class] && [engine[@"name"] isKindOfClass:NSString.class] &&
            [engine[@"url"] isKindOfClass:NSString.class])
            [engines addObject:engine];
    return engines;
}
NSDictionary *LTSelectedSearchEngine(NSDictionary *settings) {
    NSArray<NSDictionary *> *engines = LTSearchEngines(settings);
    id selected = settings[@"search"];
    for (NSDictionary *engine in engines)
        if ([engine[@"name"] isEqual:selected])
            return engine;
    return engines.firstObject;
}
NSString *LTSearchURL(NSString *query, NSDictionary *settings) {
    return Fill(LTSelectedSearchEngine(settings)[@"url"], query);
}
NSURL *LTSearchSuggestionURL(NSString *query, NSDictionary *settings) {
    if (![settings[@"searchSuggestions"] isEqual:@YES])
        return nil;
    NSString *address = LTSelectedSearchEngine(settings)[@"suggest"], *text = Trim(query);
    if (![address isKindOfClass:NSString.class] || !address.length || !text.length ||
        text.length > MaxQueryLength || !OneLine(text))
        return nil;
    // An address the Command Bar would open, or one still being typed, is not a search.
    BOOL spaced = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound;
    if (![LTURLFromInput(text, settings) isEqual:LTSearchURL(text, settings)] ||
        (!spaced && [text containsString:@":/"]))
        return nil;
    return [NSURL URLWithString:Fill(address, text)];
}
NSArray<NSString *> *LTParseSearchSuggestions(NSData *data, NSString *encoding, NSString *query) {
    if (!data.length || data.length > MaxResponseBytes)
        return @[];
    if (encoding.length && [encoding caseInsensitiveCompare:@"utf-8"] != NSOrderedSame) {
        // NSJSONSerialization reads only Unicode encodings.
        CFStringEncoding named = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)encoding);
        NSString *text = named == kCFStringEncodingInvalidId
                             ? nil
                             : [[NSString alloc] initWithData:data
                                                     encoding:CFStringConvertEncodingToNSStringEncoding(named)];
        data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: data;
    }
    NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class] || json.count < 2 || ![json[1] isKindOfClass:NSArray.class])
        return @[];
    NSMutableArray<NSString *> *suggestions = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:Trim(query).lowercaseString];
    for (id item in json[1]) {
        NSString *text = Trim(item);
        if (!text.length || text.length > MaxSuggestionLength || !OneLine(text) ||
            [seen containsObject:text.lowercaseString])
            continue;
        [seen addObject:text.lowercaseString];
        [suggestions addObject:text];
        if (suggestions.count == LTSearchSuggestionLimit)
            break;
    }
    return suggestions;
}

// A redirect would send the typed text to a host the user did not choose.
@interface LTSuggestionDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation LTSuggestionDelegate
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

@implementation LTSearchSuggestions {
    NSURLSession *_session;
    NSTimeInterval _delay;
    NSURLSessionDataTask *_task;
    NSUInteger _generation;
    NSMutableDictionary<NSURL *, NSArray<NSString *> *> *_answers;
}
- (instancetype)init {
    return [self initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delay:.15];
}
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration delay:(NSTimeInterval)delay {
    if ((self = [super init])) {
        configuration = [configuration copy];
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCredentialStorage = nil;
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 4;
        configuration.timeoutIntervalForResource = 6;
        // The session keeps its delegate, so the delegate is not this object and -dealloc can run.
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:[LTSuggestionDelegate new]
                                            delegateQueue:NSOperationQueue.mainQueue];
        _delay = delay;
        _answers = [NSMutableDictionary new];
    }
    return self;
}
- (void)dealloc {
    [_session invalidateAndCancel];
}
- (void)cancel {
    _generation++;
    [_task cancel];
    _task = nil;
}
- (void)forget {
    [self cancel];
    [_answers removeAllObjects];
}
- (BOOL)suggest:(NSString *)query
       settings:(NSDictionary *)settings
     completion:(void (^)(NSArray<NSString *> *))completion {
    [self cancel];
    NSURL *url = LTSearchSuggestionURL(query, settings);
    if (!url)
        return NO;
    if (_answers[url]) {
        completion(_answers[url]);
        return YES;
    }
    NSUInteger generation = _generation;
    NSString *typed = [query copy];
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      LTSearchSuggestions *owner = weak;
      if (!owner || owner->_generation != generation)
          return;
      NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
      request.HTTPShouldHandleCookies = NO;
      [request setValue:@"Lite-Browser" forHTTPHeaderField:@"User-Agent"];
      [request setValue:@"application/x-suggestions+json, application/json" forHTTPHeaderField:@"Accept"];
      owner->_task = [owner->_session
          dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              LTSearchSuggestions *owner = weak;
              if (!owner || owner->_generation != generation)
                  return;
              owner->_task = nil;
              BOOL answered = !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
                              ((NSHTTPURLResponse *)response).statusCode == 200;
              NSArray *suggestions =
                  answered ? LTParseSearchSuggestions(data, response.textEncodingName, typed) : @[];
              if (answered) {
                  if (owner->_answers.count >= MaxAnswers)
                      [owner->_answers removeAllObjects];
                  owner->_answers[url] = suggestions;
              }
              completion(suggestions);
            }];
      [owner->_task resume];
    });
    return YES;
}
@end
