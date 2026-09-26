#import "LTContentBlocker.h"
#include <algorithm>
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
+ (instancetype)shared {
    static LTContentBlocker *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] initWithDirectory:
            [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ContentBlocking"]];
    });
    return instance;
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
            r.pattern = S(c[@"urlFilter"] ?: @"*");
            if (!r.sensitive) r.pattern = Lower(r.pattern);
            r.domainAnchor = r.pattern.starts_with("||");
            bool left = r.pattern.starts_with('|');
            if (left) r.pattern.erase(0, r.domainAnchor ? 2 : 1);
            if (!left) r.pattern.insert(0, "*");
            if (r.pattern.ends_with('|')) r.pattern.pop_back();
            else r.pattern += '*';
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
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https", @"ws", @"wss"] containsObject:scheme]) return NO;
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
    return !allow;
}
- (NSString *)youtubeScriptForURL:(NSString *)url {
    return LTIsYouTubeURL(url) ? _youtubeScript : @"";
}
- (NSString *)cosmeticScriptForURL:(NSString *)url {
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    if (![@[@"http", @"https"] containsObject:scheme]) return @"";
    NSString *host = N(Host(url));
    NSString *cached = [_scripts objectForKey:host];
    if (cached) return cached;
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
    // :is() is forgiving: one unsupported selector cannot invalidate other rules.
    NSString *css = [NSString stringWithFormat:@":is(%@){display:none!important;}",
                     [[selectors.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@",\n"]];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[css] options:0 error:nil];
    NSString *script = [NSString stringWithFormat:
        @"(()=>{if(document.adoptedStyleSheets.some(s=>s.__liteContentBlocking))return;"
        @"const s=new CSSStyleSheet();s.replaceSync(%@[0]);"
        @"Object.defineProperty(s,'__liteContentBlocking',{value:true});"
        @"document.adoptedStyleSheets=[...document.adoptedStyleSheets,s];})()",
        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [_scripts setObject:script forKey:host cost:script.length * 2];
    return script;
}
@end

@implementation LTBlockingPolicy {
    BOOL _disabled, _cosmeticDisabled;
    NSSet<NSString *> *_disabledSites;
}
- (void)updatePreferences:(NSDictionary *)preferences {
    @synchronized (self) {
        _disabled = [preferences[@"disabled"] boolValue];
        _cosmeticDisabled = [preferences[@"cosmeticDisabled"] boolValue];
        _disabledSites = [NSSet setWithArray:preferences[@"disabledSites"] ?: @[]];
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
@end
