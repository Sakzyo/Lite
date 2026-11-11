#import "LTContentBlocker.h"
#import "LTCustomCosmetics.h"
#include "LTRegex.h"
#include <algorithm>
#include <array>
#include <os/lock.h>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

BOOL LTIsYouTubeURL(NSString *url) {
    NSURL *parsed = [NSURL URLWithString:url];
    if (![@[@"http", @"https"] containsObject:parsed.scheme.lowercaseString]) return NO;
    NSString *host = parsed.host.lowercaseString;
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    BOOL youtube = NO;
    for (NSString *domain in @[@"youtube.com", @"youtube-nocookie.com", @"youtubekids.com"])
        if ([host isEqual:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) youtube = YES;
    return youtube;
}
BOOL LTFilterYouTubeResponse(NSString *url, NSString *type, NSString *mimeType) {
    if (!LTIsYouTubeURL(url)) return NO;
    NSURL *parsed = [NSURL URLWithString:url];
    NSString *mime = [[mimeType componentsSeparatedByString:@";"][0]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (([type isEqual:@"main_frame"] || [type isEqual:@"sub_frame"]) &&
        [mime isEqual:@"text/html"]) return YES;
    if (![type isEqual:@"xmlhttprequest"] ||
        ![@[@"application/json", @"text/json", @"text/html"] containsObject:mime]) return NO;
    return [@[@"/youtubei/v1/player", @"/youtubei/v1/get_watch", @"/youtubei/v1/next",
              @"/watch", @"/playlist"] containsObject:parsed.path];
}

namespace {
using Strings = std::unordered_set<std::string>;
using Index = std::unordered_map<std::string, std::vector<size_t>>;
std::string S(NSString *s) { return s.UTF8String ?: ""; }
NSString *N(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }
std::string Lower(std::string s) {
    for (char &c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return s;
}
std::string Host(NSString *url) {
    std::string host = Lower(S([NSURL URLWithString:url].host));
    if (!host.empty() && host.back() == '.') host.pop_back();
    return host;
}
Strings Set(NSArray *values) {
    Strings result;
    for (NSString *value in values) result.insert(S(value));
    return result;
}
std::vector<std::string> Suffixes(const std::string &host) {
    std::vector<std::string> result;
    // IP addresses are hosts, not registrable domains.
    if (host.find(':') != std::string::npos ||
        host.find_first_not_of("0123456789.") == std::string::npos) return {host};
    for (size_t p = 0; p < host.size();) {
        result.push_back(host.substr(p));
        auto dot = host.find('.', p);
        if (dot == std::string::npos) break;
        p = dot + 1;
    }
    return result;
}
bool DomainMatch(const Strings &domains, const std::string &host) {
    for (const auto &suffix : Suffixes(host)) if (domains.contains(suffix)) return true;
    return false;
}
bool Separator(char c) {
    return !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '%');
}
// DNR's glob grammar, not regular expressions: * = any run, ^ = separator or end.
// A single remembered star avoids recursive/exponential matching.
bool Glob(const std::string &pattern, const std::string &url, size_t start = 0) {
    size_t p = 0, u = start, star = std::string::npos, retry = start;
    while (u < url.size()) {
        if (p < pattern.size() && pattern[p] == '*') { star = p++; retry = u; }
        else if (p < pattern.size() && (pattern[p] == url[u] ||
                                      (pattern[p] == '^' && Separator(url[u])))) { ++p; ++u; }
        else if (star != std::string::npos) { p = star + 1; u = ++retry; }
        else return false;
    }
    while (p < pattern.size() && (pattern[p] == '*' || pattern[p] == '^')) ++p;
    return p == pattern.size();
}
struct Rule {
    std::string pattern, token;
    Strings domains, excludedDomains, initiators, excludedInitiators, types, excludedTypes,
            methods, excludedMethods;
    int priority = 1, party = 0;
    bool allow = false, sensitive = false, domainAnchor = false;
    bool matches(const std::string &url, const std::string &lowerURL, const std::string &host,
                 const std::string &initiator, const std::string &type,
                 const std::string &method, bool thirdParty) const {
        if ((!types.empty() ? !types.contains(type) : type == "main_frame") ||
            excludedTypes.contains(type) || (!methods.empty() && !methods.contains(method)) ||
            excludedMethods.contains(method) || (party && (party == 2) != thirdParty) ||
            (!domains.empty() && !DomainMatch(domains, host)) || DomainMatch(excludedDomains, host) ||
            (!initiators.empty() && !DomainMatch(initiators, initiator)) ||
            DomainMatch(excludedInitiators, initiator)) return false;
        const auto &target = sensitive ? url : lowerURL;
        if (!domainAnchor) return Glob(pattern, target);
        auto start = target.find("://");
        if (start == std::string::npos) return false;
        start += 3;
        auto end = target.find_first_of("/:?#", start);
        if (end == std::string::npos) end = target.size();
        auto at = target.rfind('@', end);
        if (at != std::string::npos && at >= start) start = at + 1;
        if (Glob(pattern, target, start)) return true;
        for (auto dot = target.find('.', start); dot < end; dot = target.find('.', dot + 1))
            if (Glob(pattern, target, dot + 1)) return true;
        return false;
    }
};
void SetPattern(Rule &rule, NSString *pattern) {
    rule.pattern = S(pattern);
    if (!rule.sensitive) rule.pattern = Lower(rule.pattern);
    rule.domainAnchor = rule.pattern.starts_with("||");
    bool left = rule.pattern.starts_with('|');
    if (left) rule.pattern.erase(0, rule.domainAnchor ? 2 : 1);
    if (!left) rule.pattern.insert(0, "*");
    if (rule.pattern.ends_with('|')) rule.pattern.pop_back();
    else rule.pattern += '*';
}
BOOL CustomFilterError(NSError **error, NSUInteger line, NSString *message) {
    if (error) {
        NSString *where = line ? [NSString stringWithFormat:@"Custom filters, line %lu: ", (unsigned long)line] : @"Custom filters: ";
        *error = [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey:
            [[where stringByAppendingString:message] stringByAppendingString:@" Your previous filters were kept."]}];
    }
    return NO;
}
struct RegexRule {
    std::unique_ptr<lite::Regex> expression;
    bool allow;
};
// The two passes have independent caps so expensive blocks cannot starve an exception.
constexpr size_t RegexPassSteps = 50000, RegexURLBytes = 8192;
BOOL ParseCustomFilters(id value, std::vector<Rule> *rules,
                        std::vector<RegexRule> *regexes, NSMutableArray *cosmetics, NSError **error) {
    if (![value isKindOfClass:NSString.class]) return CustomFilterError(error, 0, @"Enter a plain-text filter list.");
    NSString *text = value;
    if (![text canBeConvertedToEncoding:NSUTF8StringEncoding] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256 * 1024)
        return CustomFilterError(error, 0, @"The list must fit within 256 KiB of UTF-8 text.");
    NSUInteger number = 0, count = 0, regexCount = 0, regexSize = 0, selectorCount = 0;
    BOOL firstNonempty = YES;
    NSCharacterSet *padding = [NSCharacterSet characterSetWithCharactersInString:@" \t"];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        ++number;
        NSString *line = [raw hasSuffix:@"\r"] ? [raw substringToIndex:raw.length - 1] : raw;
        if (line.length > 2048) return CustomFilterError(error, number, @"A line cannot exceed 2,048 characters.");
        line = [line stringByTrimmingCharactersInSet:padding];
        if (!line.length) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            if (!firstNonempty || ![@[@"[Adblock]", @"[Adblock Plus 2.0]"] containsObject:line])
                return CustomFilterError(error, number, @"Remove this list header. Only [Adblock] or [Adblock Plus 2.0] is accepted as the first nonempty line.");
            firstNonempty = NO;
            continue;
        }
        firstNonempty = NO;
        if ([line hasPrefix:@"!"]) continue;
        if (++count > 1000) return CustomFilterError(error, number, @"The list cannot exceed 1,000 rules.");
        BOOL allow = [line hasPrefix:@"@@"];
        NSString *pattern = allow ? [line substringFromIndex:2] : line;
        if (!pattern.length) return CustomFilterError(error, number, @"A rule needs a URL pattern.");
        if (pattern.length >= 2 && [pattern hasPrefix:@"/"] && [pattern hasSuffix:@"/"]) {
            NSString *body = [pattern substringWithRange:NSMakeRange(1, pattern.length - 2)];
            if (!body.length) return CustomFilterError(error, number, @"A regular expression cannot be empty.");
            for (NSUInteger i = 0; i < body.length; ++i)
                if ([body characterAtIndex:i] < 32 || [body characterAtIndex:i] >= 127)
                    return CustomFilterError(error, number, @"Regular expressions must use printable ASCII; use escapes for control characters.");
            if (++regexCount > 32) return CustomFilterError(error, number, @"The list cannot exceed 32 regular expressions.");
            std::string reason;
            auto expression = lite::Regex::Compile(S(body), reason);
            if (!expression) return CustomFilterError(error, number,
                [@"Invalid regular expression: " stringByAppendingString:N(reason)]);
            regexSize += expression->programSize();
            if (regexSize > 2048) return CustomFilterError(error, number,
                @"Regular expressions together cannot exceed 2,048 compiled instructions. Simplify the expressions.");
            if (regexes) regexes->push_back({std::move(expression), bool(allow)});
            continue;
        }
        if ([line containsString:@"##"] || [line containsString:@"#@#"]) {
            NSString *reason = nil;
            NSDictionary *filter = LTParseCustomCosmeticFilter(line, &reason);
            if (!filter) return CustomFilterError(error, number, reason);
            for (NSString *selector in filter[@"selectors"]) {
                if (++selectorCount > 1000) return CustomFilterError(error, number,
                    @"The list cannot exceed 1,000 cosmetic selectors, including comma-separated selectors.");
                [cosmetics addObject:@{@"host": filter[@"host"], @"selector": selector,
                                       @"exception": filter[@"exception"]}];
            }
            continue;
        }
        if ([line containsString:@"#?#"] || [line containsString:@"#$#"] || [line containsString:@"#%#"])
            return CustomFilterError(error, number, @"Procedural cosmetic filters and scriptlets are not supported.");
        for (NSUInteger i = 0; i < pattern.length; ++i) {
            unichar c = [pattern characterAtIndex:i];
            if (c <= 32 || c >= 127) return CustomFilterError(error, number, @"URL patterns must use ASCII without spaces or control characters.");
            if (c == '$' || c == '#') return CustomFilterError(error, number, @"Filter options and this cosmetic syntax are not supported.");
        }
        NSString *body = pattern;
        if ([body hasPrefix:@"||"]) body = [body substringFromIndex:2];
        else if ([body hasPrefix:@"|"]) body = [body substringFromIndex:1];
        if ([body hasSuffix:@"|"]) body = [body substringToIndex:body.length - 1];
        if (!body.length || [body containsString:@"|"])
            return CustomFilterError(error, number, @"Use | only at the ends, or || at the start, of a nonempty pattern.");
        if (rules) {
            Rule rule;
            rule.allow = allow;
            SetPattern(rule, pattern);
            // Every match must contain this literal, including domain-anchored rules.
            std::string run;
            for (char ch : rule.pattern) {
                if (ch == '*' || ch == '^') run.clear();
                else { run += ch; if (run.size() > rule.token.size()) rule.token = run; }
            }
            rules->push_back(std::move(rule));
        }
    }
    return YES;
}

// Split only top-level list commas. Bundled selectors also use functions, quoted
// attributes, escapes and comments; keep an unfamiliar/malformed list intact.
NSArray<NSString *> *CosmeticSelectorParts(NSString *selector) {
    if (![selector containsString:@","]) return @[selector];
    NSMutableArray *parts = [NSMutableArray new];
    NSCharacterSet *spaces = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\f"];
    std::array<unichar, 64> nesting;
    NSUInteger depth = 0, start = 0;
    unichar quote = 0;
    BOOL comment = NO;
    for (NSUInteger i = 0; i < selector.length; ++i) {
        unichar c = [selector characterAtIndex:i];
        unichar next = i + 1 < selector.length ? [selector characterAtIndex:i + 1] : 0;
        if (comment) {
            if (c == '*' && next == '/') { comment = NO; ++i; }
            continue;
        }
        if (c == '\\') {
            if (i + 1 == selector.length) return @[selector];
            ++i;
            continue;
        }
        if (quote) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' || c == '"') quote = c;
        else if (c == '/' && next == '*') { comment = YES; ++i; }
        else if (c == '(' || c == '[') {
            if (depth == nesting.size()) return @[selector];
            nesting[depth++] = c;
        } else if (c == ')' || c == ']') {
            if (!depth || nesting[depth - 1] != (c == ')' ? '(' : '[')) return @[selector];
            --depth;
        } else if (c == ',' && !depth) {
            NSString *part = [[selector substringWithRange:NSMakeRange(start, i - start)]
                stringByTrimmingCharactersInSet:spaces];
            if (!part.length) return @[selector];
            [parts addObject:part];
            start = i + 1;
        }
    }
    if (quote || comment || depth) return @[selector];
    NSString *part = [[selector substringFromIndex:start] stringByTrimmingCharactersInSet:spaces];
    if (!part.length) return @[selector];
    [parts addObject:part];
    return parts;
}
}

BOOL LTValidateCustomFilters(id text, NSError **error) {
    return ParseCustomFilters(text, nullptr, nullptr, nil, error);
}

static NSString *CosmeticScript(NSSet<NSString *> *selectors);
@interface LTContentBlocker ()
- (NSSet<NSString *> *)cosmeticSelectorsForURL:(NSString *)url;
@end

// A policy swaps this immutable matcher as a whole; request threads retain their snapshot.
@interface LTCustomFilterSet : NSObject
@property (nonatomic, copy, readonly) NSString *text;
- (instancetype)initWithText:(NSString *)text;
- (LTNetworkDecision)decisionForURL:(NSString *)url type:(NSString *)type;
- (BOOL)hasCosmetics;
- (NSString *)cosmeticScriptForURL:(NSString *)url bundled:(LTContentBlocker *)bundled;
@end
@implementation LTCustomFilterSet {
    std::vector<Rule> _rules;
    std::vector<RegexRule> _regexes;
    NSArray<NSDictionary *> *_cosmetics;
    NSCache<NSString *, NSString *> *_scripts;
    LTContentBlocker *_scriptsBundle;
}
- (instancetype)initWithText:(NSString *)text {
    if ((self = [super init])) {
        _text = [text copy];
        NSMutableArray *cosmetics = [NSMutableArray new];
        if (!ParseCustomFilters(_text, &_rules, &_regexes, cosmetics, nil)) return nil;
        _cosmetics = [cosmetics copy];
    }
    return self;
}
- (LTNetworkDecision)decisionForURL:(NSString *)url type:(NSString *)type {
    if ((_rules.empty() && _regexes.empty()) || [type isEqual:@"main_frame"]) return LTNetworkNoMatch;
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https", @"ws", @"wss"] containsObject:scheme]) return LTNetworkNoMatch;
    std::string full = S(url), lower = Lower(full), host = Host(url), resource = S(type);
    LTNetworkDecision decision = LTNetworkNoMatch;
    for (const Rule &rule : _rules) {
        if (rule.token.size() >= 5 && lower.find(rule.token) == std::string::npos) continue;
        if (!rule.matches(full, lower, host, "", resource, "", false)) continue;
        if (rule.allow) return LTNetworkAllow;
        decision = LTNetworkBlock;
    }
    // Never truncate: matching an incomplete URL could turn a nonmatch into a block/exception.
    if (_regexes.empty() || full.size() > RegexURLBytes) return decision;
    for (bool allow : {true, false}) {
        if (!allow && decision == LTNetworkBlock) return decision;
        size_t remaining = RegexPassSteps;
        for (const RegexRule &rule : _regexes) {
            if (rule.allow != allow) continue;
            auto result = rule.expression->search(full, remaining);
            if (result == lite::MatchResult::LimitExceeded) return decision;
            if (result == lite::MatchResult::Match) return allow ? LTNetworkAllow : LTNetworkBlock;
        }
    }
    return decision;
}
- (BOOL)hasCosmetics { return _cosmetics.count != 0; }
- (NSString *)cosmeticScriptForURL:(NSString *)url bundled:(LTContentBlocker *)bundled {
    NSString *host = N(Host(url));
    NSCache<NSString *, NSString *> *scripts;
    @synchronized (self) {
        // Custom identity is implicit in this owner. Retain the bundled identity,
        // and replace the cache whole so an in-flight build cannot seed a new snapshot.
        if (!_scripts || _scriptsBundle != bundled) {
            _scriptsBundle = bundled;
            _scripts = [NSCache new];
            _scripts.countLimit = 16;
            _scripts.totalCostLimit = 8 * 1024 * 1024;
        }
        scripts = _scripts;
    }
    NSString *cached = [scripts objectForKey:host];
    if (cached) return cached;
    NSMutableArray<NSDictionary *> *matching = [NSMutableArray new];
    for (NSDictionary *filter in _cosmetics) {
        NSString *scope = filter[@"host"];
        if (scope.length && ![host isEqual:scope] && ![host hasSuffix:[@"." stringByAppendingString:scope]]) continue;
        [matching addObject:filter];
    }
    NSString *script;
    if (!matching.count) script = [bundled cosmeticScriptForURL:url] ?: @"";
    else {
        // Bundled exceptions have already been applied to their original list strings.
        NSMutableSet *selectors = [NSMutableSet new];
        for (NSString *selector in [bundled cosmeticSelectorsForURL:url])
            [selectors addObjectsFromArray:CosmeticSelectorParts(selector)];
        NSMutableSet *exceptions = [NSMutableSet new];
        for (NSDictionary *filter in matching) {
            if ([filter[@"exception"] boolValue]) [exceptions addObject:filter[@"selector"]];
            else [selectors addObject:filter[@"selector"]];
        }
        [selectors minusSet:exceptions];
        script = CosmeticScript(selectors);
    }
    [scripts setObject:script forKey:host cost:script.length * 2];
    return script;
}
@end

// Both bundled-only and per-context styles use the same injection/marker path.
static NSString *CosmeticScript(NSSet<NSString *> *selectors) {
    // :is() is forgiving for upstream selectors unsupported by this Chromium version.
    NSString *css = [NSString stringWithFormat:@":is(%@){display:none!important;}",
        [[selectors.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@",\n"]];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[css] options:0 error:nil];
    return [NSString stringWithFormat:
        @"(()=>{if(document.adoptedStyleSheets.some(s=>s.__liteContentBlocking))return;"
        @"const s=new CSSStyleSheet();s.replaceSync(%@[0]);"
        @"Object.defineProperty(s,'__liteContentBlocking',{value:true});"
        @"document.adoptedStyleSheets=[...document.adoptedStyleSheets,s];})()",
        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

@implementation LTContentBlocker {
    std::vector<Rule> _rules;
    Index _domainIndex, _tokenIndex;
    std::vector<size_t> _unindexed;
    Strings _suffixes;
    NSDictionary *_cosmetic;
    NSCache<NSString *, NSString *> *_scripts;
    NSString *_youtubeScript;
}
static LTContentBlocker *currentBlocker;
static os_unfair_lock blockerLock = OS_UNFAIR_LOCK_INIT;
+ (NSString *)bundledDirectory {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ContentBlocking"];
}
+ (instancetype)shared {
    os_unfair_lock_lock(&blockerLock);
    LTContentBlocker *blocker = currentBlocker;
    os_unfair_lock_unlock(&blockerLock);
    if (blocker) return blocker;
    static LTContentBlocker *bundled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundled = [[self alloc] initWithDirectory:[self bundledDirectory]];
    });
    os_unfair_lock_lock(&blockerLock);
    if (!currentBlocker) currentBlocker = bundled;
    blocker = currentBlocker;
    os_unfair_lock_unlock(&blockerLock);
    return blocker;
}
+ (void)install:(LTContentBlocker *)blocker {
    os_unfair_lock_lock(&blockerLock);
    currentBlocker = blocker;
    os_unfair_lock_unlock(&blockerLock);
}
- (int64_t)serial {
    id serial = _provenance[@"serial"];
    return [serial isKindOfClass:NSNumber.class] ? [serial longLongValue] : 0;
}
- (instancetype)initWithDirectory:(NSString *)directory {
    if (!(self = [super init])) return nil;
    @autoreleasepool {
        id (^read)(NSString *) = ^id(NSString *name) {
            NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
            return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        };
        NSArray *raw = read(@"network.json");
        _cosmetic = read(@"cosmetic.json");
        _provenance = read(@"provenance.json");
        _youtubeScript = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"youtube.js"]
                                                  encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *psl = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"suffixes.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
        if (![raw isKindOfClass:NSArray.class] || ![_cosmetic isKindOfClass:NSDictionary.class] ||
            ![_provenance isKindOfClass:NSDictionary.class] || !psl.length) return nil;
        _suffixes = Set([psl componentsSeparatedByString:@"\n"]);
        _scripts = [NSCache new];
        _scripts.countLimit = 16;
        _scripts.totalCostLimit = 8 * 1024 * 1024;
        _rules.reserve(raw.count);
        std::unordered_map<std::string, size_t> frequencies;
        for (NSDictionary *entry in raw) {
            NSDictionary *c = entry[@"condition"];
            Rule r;
            r.allow = [entry[@"action"][@"type"] isEqual:@"allow"];
            r.priority = entry[@"priority"] ? [entry[@"priority"] intValue] : 1;
            r.sensitive = [c[@"isUrlFilterCaseSensitive"] boolValue];
            SetPattern(r, c[@"urlFilter"] ?: @"*");
            r.domains = Set(c[@"requestDomains"]); r.excludedDomains = Set(c[@"excludedRequestDomains"]);
            r.initiators = Set(c[@"initiatorDomains"]); r.excludedInitiators = Set(c[@"excludedInitiatorDomains"]);
            r.types = Set(c[@"resourceTypes"]); r.excludedTypes = Set(c[@"excludedResourceTypes"]);
            r.methods = Set(c[@"requestMethods"]); r.excludedMethods = Set(c[@"excludedRequestMethods"]);
            r.party = [c[@"domainType"] isEqual:@"thirdParty"] ? 2 : [c[@"domainType"] isEqual:@"firstParty"] ? 1 : 0;
            // Select a rare mandatory five-byte literal to narrow URL candidates.
            std::string longest, run;
            for (char ch : Lower(r.pattern)) {
                if (ch == '*' || ch == '^') run.clear();
                else { run += ch; if (run.size() > longest.size()) longest = run; }
            }
            r.token = longest;
            if (r.domains.empty() && longest.size() >= 5)
                for (size_t i = 0; i + 5 <= longest.size(); ++i) ++frequencies[longest.substr(i, 5)];
            _rules.push_back(std::move(r));
        }
        for (size_t i = 0; i < _rules.size(); ++i) {
            Rule &r = _rules[i];
            if (!r.domains.empty()) {
                for (const auto &domain : r.domains) _domainIndex[domain].push_back(i);
            } else if (r.token.size() >= 5) {
                std::string chosen = r.token.substr(0, 5);
                for (size_t j = 1; j + 5 <= r.token.size(); ++j) {
                    auto candidate = r.token.substr(j, 5);
                    if (frequencies[candidate] < frequencies[chosen]) chosen = candidate;
                }
                _tokenIndex[chosen].push_back(i);
            } else _unindexed.push_back(i);
            r.token.clear();
        }
    }
    return self;
}
- (NSString *)siteForHost:(NSString *)value {
    std::string host = Lower(S(value));
    if (!host.empty() && host.back() == '.') host.pop_back();
    auto parts = Suffixes(host);
    for (size_t i = 0; i < parts.size(); ++i) {
        if (_suffixes.contains("!" + parts[i])) return N(parts[i]);
        bool wildcard = i + 1 < parts.size() && _suffixes.contains("*." + parts[i + 1]);
        if (_suffixes.contains(parts[i]) || wildcard) return N(parts[i ? i - 1 : 0]);
    }
    return N(parts.size() > 1 ? parts[parts.size() - 2] : host);
}
- (BOOL)blocksURL:(NSString *)url initiator:(NSString *)initiator type:(NSString *)type method:(NSString *)method {
    return [self decisionForURL:url initiator:initiator type:type method:method] == LTNetworkBlock;
}
- (LTNetworkDecision)decisionForURL:(NSString *)url initiator:(NSString *)initiator type:(NSString *)type method:(NSString *)method {
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https", @"ws", @"wss"] containsObject:scheme]) return LTNetworkNoMatch;
    std::string full = S(url), lower = Lower(full), host = Host(url), source = Host(initiator);
    // Opaque/missing initiators are distinct from the destination, as in DNR.
    bool thirdParty = source.empty() || ![[self siteForHost:N(host)] isEqual:[self siteForHost:N(source)]];
    std::vector<size_t> candidates = _unindexed;
    auto append = [&](const Index &index, const std::string &key) {
        auto it = index.find(key);
        if (it != index.end()) candidates.insert(candidates.end(), it->second.begin(), it->second.end());
    };
    for (const auto &suffix : Suffixes(host)) append(_domainIndex, suffix);
    Strings seen;
    for (size_t i = 0; i + 5 <= lower.size(); ++i) {
        auto key = lower.substr(i, 5);
        if (seen.insert(key).second) append(_tokenIndex, key);
    }
    std::sort(candidates.begin(), candidates.end());
    candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());
    int priority = -1;
    bool allow = true;
    const auto resource = S(type), verb = Lower(S(method));
    for (size_t i : candidates) {
        const Rule &r = _rules[i];
        if (r.priority < priority || (r.priority == priority && allow && !r.allow)) continue;
        if (r.matches(full, lower, host, source, resource, verb, thirdParty)) {
            priority = r.priority;
            allow = r.allow;
        }
    }
    return priority < 0 ? LTNetworkNoMatch : allow ? LTNetworkAllow : LTNetworkBlock;
}
- (NSString *)youtubeScriptForURL:(NSString *)url {
    return LTIsYouTubeURL(url) ? _youtubeScript : @"";
}
- (NSSet<NSString *> *)cosmeticSelectorsForURL:(NSString *)url {
    NSString *host = N(Host(url));
    NSMutableSet *selectors = [NSMutableSet setWithArray:_cosmetic[@"generic"]];
    NSMutableSet *exceptions = [NSMutableSet new];
    NSMutableArray *keys = [NSMutableArray arrayWithObject:@"*"];
    for (const auto &s : Suffixes(S(host))) [keys addObject:N(s)];
    NSString *site = [self siteForHost:host];
    NSRange dot = [site rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        NSString *suffix = [site substringFromIndex:dot.location];
        NSString *entity = [host substringToIndex:host.length - suffix.length];
        for (const auto &s : Suffixes(S(entity))) [keys addObject:[N(s) stringByAppendingString:@".*"]];
    }
    for (NSString *key in keys) {
        [selectors addObjectsFromArray:_cosmetic[@"specific"][key] ?: @[]];
        [exceptions addObjectsFromArray:_cosmetic[@"exceptions"][key] ?: @[]];
    }
    [selectors minusSet:exceptions];
    return selectors;
}
- (NSString *)cosmeticScriptForURL:(NSString *)url {
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https"] containsObject:scheme]) return @"";
    NSString *host = N(Host(url));
    NSString *cached = [_scripts objectForKey:host];
    if (cached) return cached;
    NSString *script = CosmeticScript([self cosmeticSelectorsForURL:url]);
    [_scripts setObject:script forKey:host cost:script.length * 2];
    return script;
}
@end

@implementation LTBlockingPolicy {
    BOOL _disabled, _cosmeticDisabled;
    NSSet<NSString *> *_disabledSites;
    LTCustomFilterSet *_custom;
}
- (void)updatePreferences:(NSDictionary *)preferences {
    if (preferences && ![preferences isKindOfClass:NSDictionary.class]) return;
    for (NSString *key in @[@"disabled", @"cosmeticDisabled", @"updatesDisabled"]) {
        id value = preferences[key];
        if (value && (![value isKindOfClass:NSNumber.class] || (![value isEqual:@0] && ![value isEqual:@1]))) return;
    }
    id sites = preferences[@"disabledSites"] ?: @[];
    if (![sites isKindOfClass:NSArray.class]) return;
    for (id host in sites) if (![host isKindOfClass:NSString.class] || ![host length]) return;
    id text = preferences[@"customFilters"] ?: @"";
    if (![text isKindOfClass:NSString.class]) return;
    LTCustomFilterSet *custom;
    @synchronized (self) { custom = _custom; }
    if (![custom.text isEqual:text]) custom = [[LTCustomFilterSet alloc] initWithText:text];
    if (!custom) return; // Reject the entire update, including toggles, if any rule is invalid.
    NSSet *disabledSites = [NSSet setWithArray:sites];
    @synchronized (self) {
        _disabled = [preferences[@"disabled"] boolValue];
        _cosmeticDisabled = [preferences[@"cosmeticDisabled"] boolValue];
        _disabledSites = disabledSites;
        _custom = custom;
    }
}
- (BOOL)enabledForURL:(NSString *)url {
    @synchronized (self) {
        return !_disabled && ![_disabledSites containsObject:N(Host(url))];
    }
}
- (BOOL)cosmeticEnabledForURL:(NSString *)url {
    @synchronized (self) { return !_cosmeticDisabled && [self enabledForURL:url]; }
}
- (NSString *)cosmeticScriptForURL:(NSString *)url topURL:(NSString *)topURL {
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https"] containsObject:scheme]) return @"";
    LTCustomFilterSet *custom;
    @synchronized (self) {
        // Preserve the existing top-page pause behavior for every embedded frame.
        if (_disabled || _cosmeticDisabled || [_disabledSites containsObject:N(Host(topURL))]) return @"";
        custom = _custom;
    }
    LTContentBlocker *bundled = [LTContentBlocker shared];
    if (![custom hasCosmetics]) return [bundled cosmeticScriptForURL:url] ?: @"";
    return [custom cosmeticScriptForURL:url bundled:bundled];
}
- (BOOL)blocksURL:(NSString *)url initiator:(NSString *)initiator type:(NSString *)type
          method:(NSString *)method topURL:(NSString *)topURL {
    NSString *host = N(Host(topURL));
    LTCustomFilterSet *custom;
    @synchronized (self) {
        if (_disabled || [_disabledSites containsObject:host]) return NO;
        custom = _custom;
    }
    LTNetworkDecision decision = [custom decisionForURL:url type:type];
    if (decision == LTNetworkNoMatch)
        decision = [[LTContentBlocker shared] decisionForURL:url initiator:initiator type:type method:method];
    return decision == LTNetworkBlock;
}
@end
