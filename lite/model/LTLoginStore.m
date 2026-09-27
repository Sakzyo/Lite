#import "LTLoginStore.h"
#import "LTLoginVault.h"
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
    LTLoginVault *_vault;
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
        _vault = [[LTLoginVault alloc] initWithProfilePath:path
            keyService:[_service stringByAppendingString:@".vault"]];
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
// Read only this profile's older Lite entries. Unrelated Apple Passwords and
// GitHub tokens stay in Keychain. Originals are deleted only after a vault commit.
- (NSArray *)legacyRecords:(NSError **)error {
    NSMutableDictionary *query = [self queryForEntry:nil];
    query[(id)kSecReturnAttributes] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSArray *items = CFBridgingRelease(result);
    if (status == errSecItemNotFound) return @[];
    if (!Status(status, error)) return nil;
    NSMutableArray *records = [NSMutableArray new];
    for (NSDictionary *item in items) {
        NSData *data = item[(id)kSecAttrGeneric];
        id entry = [data isKindOfClass:NSData.class]
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"origin"] isKindOfClass:NSString.class] ||
            ![entry[@"username"] isKindOfClass:NSString.class] ||
            ![LTLoginOrigin(entry[@"origin"]) isEqual:entry[@"origin"]] ||
            [entry[@"username"] length] > 1024 ||
            ![[self queryForEntry:entry][(id)kSecAttrAccount] isEqual:item[(id)kSecAttrAccount]]) {
            Status(errSecDecode, error);
            return nil;
        }
        // The macOS login Keychain does not support returning data for all
        // matches. Read each validated legacy entry separately.
        NSMutableDictionary *read = [self queryForEntry:entry];
        read[(id)kSecReturnData] = @YES;
        CFTypeRef secret = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &secret);
        NSData *passwordData = CFBridgingRelease(secret);
        if (!Status(status, error)) return nil;
        NSString *password = [[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding];
        if (!password.length || password.length > 16384) { Status(errSecDecode, error); return nil; }
        [records addObject:@{@"origin": entry[@"origin"], @"username": entry[@"username"], @"password": password}];
    }
    return records;
}
- (BOOL)withRecords:(BOOL (^)(NSMutableArray *, BOOL *, NSError **))action error:(NSError **)error {
    __block NSArray *legacy;
    return [_vault withRecords:^BOOL(NSMutableArray *records, BOOL *changed, NSError **failure) {
        legacy = [self legacyRecords:failure];
        if (!legacy) return NO;
        for (NSDictionary *old in legacy) {
            BOOL found = NO;
            for (NSDictionary *record in records)
                if ([record[@"origin"] isEqual:old[@"origin"]] &&
                    [record[@"username"] isEqual:old[@"username"]]) { found = YES; break; }
            // A partially completed migration must never replace newer vault data.
            if (!found) [records addObject:old];
        }
        *changed = legacy.count > 0;
        return action(records, changed, failure);
    } afterCommit:^BOOL(NSError **failure) {
        for (NSDictionary *old in legacy) {
            OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self queryForEntry:old]);
            if (status != errSecItemNotFound && !Status(status, failure)) return NO;
        }
        return YES;
    } error:error];
}
- (NSArray<NSDictionary *> *)entriesForOrigin:(NSString *)origin error:(NSError **)error {
    NSMutableArray *entries = [NSMutableArray new];
    BOOL ok = [self withRecords:^BOOL(NSMutableArray *records, BOOL *changed, NSError **failure) {
        for (NSDictionary *record in records)
            if (!origin || [record[@"origin"] isEqual:origin])
                [entries addObject:@{@"origin": record[@"origin"], @"username": record[@"username"]}];
        return YES;
    } error:error];
    return ok ? [entries sortedArrayUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"origin" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"username" ascending:YES]]] : nil;
}
- (BOOL)saveUsername:(NSString *)username password:(NSString *)password
              origin:(NSString *)origin error:(NSError **)error {
    if (![LTLoginOrigin(origin) isEqual:origin] || !password.length || password.length > 16384 ||
        username.length > 1024) return Status(errSecParam, error);
    return [self withRecords:^BOOL(NSMutableArray *records, BOOL *changed, NSError **failure) {
        NSIndexSet *matches = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
            return [row[@"origin"] isEqual:origin] && [row[@"username"] isEqual:username ?: @""];
        }];
        [records removeObjectsAtIndexes:matches];
        [records addObject:@{@"origin": origin, @"username": username ?: @"", @"password": password}];
        *changed = YES;
        return YES;
    } error:error];
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
    __block NSString *password = nil;
    BOOL ok = [self withRecords:^BOOL(NSMutableArray *records, BOOL *changed, NSError **failure) {
        for (NSDictionary *record in records)
            if ([record[@"origin"] isEqual:entry[@"origin"]] &&
                [record[@"username"] isEqual:entry[@"username"]]) { password = record[@"password"]; break; }
        return YES;
    } error:error];
    if (ok && !password) Status(errSecItemNotFound, error);
    return ok ? password : nil;
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
    if (entry[@"keychainReference"] || ![LTLoginOrigin(entry[@"origin"]) isEqual:entry[@"origin"]] ||
        ![entry[@"username"] isKindOfClass:NSString.class]) return Status(errSecParam, error);
    return [self withRecords:^BOOL(NSMutableArray *records, BOOL *changed, NSError **failure) {
        NSIndexSet *matches = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
            return [row[@"origin"] isEqual:entry[@"origin"]] && [row[@"username"] isEqual:entry[@"username"]];
        }];
        [records removeObjectsAtIndexes:matches];
        *changed = *changed || matches.count > 0;
        return YES;
    } error:error];
}
@end
