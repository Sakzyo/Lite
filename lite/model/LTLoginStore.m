#import "LTLoginStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
NSString *LTLoginOrigin(NSString *url) {
    if (!url.length)
        return nil;
    NSURLComponents *u = [NSURLComponents componentsWithString:url];
    NSString *scheme = u.scheme.lowercaseString, *host = u.host.lowercaseString;
    BOOL local = [@[ @"localhost", @"127.0.0.1", @"[::1]", @"::1" ] containsObject:host];
    if (!host.length || u.user.length || u.password.length ||
        (![scheme isEqual:@"https"] && !([scheme isEqual:@"http"] && local)))
        return nil;
    u.scheme = scheme;
    u.host = host;
    u.path = @"";
    u.query = nil;
    u.fragment = nil;
    if (([scheme isEqual:@"https"] && u.port.integerValue == 443) ||
        ([scheme isEqual:@"http"] && u.port.integerValue == 80))
        u.port = nil;
    return u.URL.absoluteString;
}
static BOOL Status(OSStatus status, NSError **error) {
    if (status == errSecSuccess)
        return YES;
    if (error)
        *error =
            [NSError errorWithDomain:NSOSStatusErrorDomain
                                code:status
                            userInfo:@{
                                NSLocalizedDescriptionKey :
                                        CFBridgingRelease(SecCopyErrorMessageString(status, NULL))
                                    ?: @"Keychain could not complete the request."
                            }];
    return NO;
}
@implementation LTLoginStore {
    NSString *_service;
}
- (instancetype)initWithProfilePath:(NSString *)path {
    if ((self = [super init])) {
        NSData *data = [path.stringByStandardizingPath dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
        NSMutableString *suffix = [NSMutableString new];
        for (NSUInteger i = 0; i < sizeof(hash); i++)
            [suffix appendFormat:@"%02x", hash[i]];
        _service = [@"app.lite.browser.logins." stringByAppendingString:suffix];
    }
    return self;
}
- (NSMutableDictionary *)queryForEntry:(NSDictionary *)entry {
    NSMutableDictionary *query =
        [@{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : _service}
            mutableCopy];
    if (entry) {
        NSData *identity =
            [NSJSONSerialization dataWithJSONObject:@[ entry[@"origin"], entry[@"username"] ]
                                            options:0
                                              error:nil];
        query[(id)kSecAttrAccount] = [identity base64EncodedStringWithOptions:0];
    }
    return query;
}
- (NSArray<NSDictionary *> *)entriesForOrigin:(NSString *)origin error:(NSError **)error {
    NSMutableDictionary *query = [self queryForEntry:nil];
    query[(id)kSecReturnAttributes] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSArray *attributes = CFBridgingRelease(result);
    if (status == errSecItemNotFound)
        return @[];
    if (!Status(status, error))
        return nil;
    NSMutableArray *entries = [NSMutableArray new];
    for (NSDictionary *item in attributes) {
        NSData *data = item[(id)kSecAttrGeneric];
        NSDictionary *entry =
            data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"origin"] isKindOfClass:NSString.class] ||
            ![entry[@"username"] isKindOfClass:NSString.class] ||
            ![LTLoginOrigin(entry[@"origin"]) isEqual:entry[@"origin"]])
            continue;
        if (!origin || [origin isEqual:entry[@"origin"]])
            [entries addObject:entry];
    }
    return [entries sortedArrayUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"origin" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"username" ascending:YES]
    ]];
}
- (BOOL)saveUsername:(NSString *)username
            password:(NSString *)password
              origin:(NSString *)origin
               error:(NSError **)error {
    if (![LTLoginOrigin(origin) isEqual:origin] || !password.length || password.length > 16384 ||
        username.length > 1024)
        return Status(errSecParam, error);
    NSDictionary *entry = @{@"origin" : origin, @"username" : username ?: @""};
    NSMutableDictionary *query = [self queryForEntry:entry];
    NSDictionary *attributes = @{
        (id)kSecValueData : [password dataUsingEncoding:NSUTF8StringEncoding],
        (id)kSecAttrGeneric : [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil],
        (id)kSecAttrLabel : [@"Lite — " stringByAppendingString:origin]
    };
    OSStatus status =
        SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    return Status(status, error);
}
- (NSString *)passwordForEntry:(NSDictionary *)entry error:(NSError **)error {
    if ([entry[@"keychainReference"] isKindOfClass:NSData.class]) {
        NSDictionary *query = @{
            (id)kSecClass: (id)kSecClassInternetPassword,
            (id)kSecValuePersistentRef: entry[@"keychainReference"],
            (id)kSecReturnAttributes: @YES, (id)kSecReturnData: @YES,
            (id)kSecMatchLimit: (id)kSecMatchLimitOne
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        NSDictionary *item = CFBridgingRelease(result);
        if (!Status(status, error)) return nil;
        NSURLComponents *url = [NSURLComponents componentsWithString:entry[@"origin"]];
        NSInteger port = url.port ? url.port.integerValue : 443;
        NSInteger itemPort = [item[(id)kSecAttrPort] integerValue] ?: 443;
        if (![LTLoginOrigin(entry[@"origin"]) isEqual:entry[@"origin"]] ||
            ![item[(id)kSecAttrServer] isEqual:url.host] ||
            ![item[(id)kSecAttrProtocol] isEqual:(id)kSecAttrProtocolHTTPS] ||
            ![item[(id)kSecAttrAccount] isEqual:entry[@"username"]] || port != itemPort) {
            Status(errSecParam, error);
            return nil;
        }
        return [[NSString alloc] initWithData:item[(id)kSecValueData] encoding:NSUTF8StringEncoding];
    }
    NSMutableDictionary *query = [self queryForEntry:entry];
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = CFBridgingRelease(result);
    return Status(status, error)
               ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
               : nil;
}
- (NSArray<NSDictionary *> *)keychainEntriesForOrigin:(NSString *)origin error:(NSError **)error {
    if (![LTLoginOrigin(origin) isEqual:origin] || ![origin hasPrefix:@"https://"])
        return @[];
    NSURLComponents *url = [NSURLComponents componentsWithString:origin];
    NSDictionary *query = @{
        (id)kSecClass: (id)kSecClassInternetPassword,
        (id)kSecAttrServer: url.host, (id)kSecAttrProtocol: (id)kSecAttrProtocolHTTPS,
        (id)kSecReturnAttributes: @YES, (id)kSecReturnPersistentRef: @YES,
        (id)kSecMatchLimit: (id)kSecMatchLimitAll
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSArray *items = CFBridgingRelease(result);
    if (status == errSecItemNotFound) return @[];
    if (!Status(status, error)) return nil;
    NSMutableArray *entries = [NSMutableArray new];
    NSInteger port = url.port ? url.port.integerValue : 443;
    for (NSDictionary *item in items) {
        NSInteger itemPort = [item[(id)kSecAttrPort] integerValue] ?: 443;
        if (itemPort != port || ![item[(id)kSecValuePersistentRef] isKindOfClass:NSData.class] ||
            ![item[(id)kSecAttrAccount] isKindOfClass:NSString.class]) continue;
        [entries addObject:@{@"origin": origin, @"username": item[(id)kSecAttrAccount],
            @"keychainReference": item[(id)kSecValuePersistentRef],
            @"keychainPath": item[(id)kSecAttrPath] ?: @"/"}];
    }
    return entries;
}
- (NSDictionary *)githubQuery {
    return @{(id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: [_service stringByAppendingString:@".github"],
        (id)kSecAttrAccount: @"GitHub API token"};
}
- (NSString *)githubToken:(NSError **)error {
    NSMutableDictionary *query = [[self githubQuery] mutableCopy];
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = CFBridgingRelease(result);
    if (status == errSecItemNotFound) return @"";
    return Status(status, error) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
- (BOOL)setGitHubToken:(NSString *)token error:(NSError **)error {
    NSMutableDictionary *query = [[self githubQuery] mutableCopy];
    if (!token.length) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecItemNotFound || Status(status, error);
    }
    NSDictionary *attributes = @{(id)kSecValueData: [token dataUsingEncoding:NSUTF8StringEncoding],
        (id)kSecAttrLabel: @"Lite — GitHub Live Folders"};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    return Status(status, error);
}
- (BOOL)deleteEntry:(NSDictionary *)entry error:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self queryForEntry:entry]);
    return status == errSecItemNotFound || Status(status, error);
}
@end
