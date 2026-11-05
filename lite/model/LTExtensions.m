#import "LTExtensions.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include <libkern/OSByteOrder.h>
#include <stdlib.h>

NSString *const LTExtensionsChanged = @"LTExtensionsChanged";
// Sent to the Web Store update service; keep in step with the pinned CEF SDK.
static NSString *const ChromiumVersion = @LITE_CHROMIUM_VERSION;
static const NSUInteger MaximumPackageSize = 256 * 1024 * 1024;

static NSError *Failure(NSString *message) {
    return [NSError errorWithDomain:@"LTExtensions" code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static id FailNil(NSError **error, NSString *message) {
    if (error) *error = Failure(message);
    return nil;
}
static NSData *SHA256(NSData *data) {
    NSMutableData *digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest.mutableBytes);
    return digest;
}
// Chromium IDs are the first 128 bits of a SHA-256 digest, written with a-p for 0-f.
static NSString *IDFromBytes(NSData *bytes) {
    const uint8_t *digest = SHA256(bytes).bytes;
    char identifier[33];
    for (int i = 0; i < 16; i++) {
        identifier[i * 2] = 'a' + (digest[i] >> 4);
        identifier[i * 2 + 1] = 'a' + (digest[i] & 15);
    }
    identifier[32] = 0;
    return @(identifier);
}
NSString *LTExtensionIDForKey(NSData *publicKey) {
    return IDFromBytes(publicKey);
}
NSString *LTExtensionIDForPath(NSString *realPath) {
    // Chromium hashes the realpath bytes of an unpacked directory without normalization.
    const char *path = realPath.UTF8String ?: "";
    return IDFromBytes([NSData dataWithBytes:path length:strlen(path)]);
}
BOOL LTValidExtensionID(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || identifier.length != 32) return NO;
    for (NSUInteger i = 0; i < 32; i++) {
        unichar c = [identifier characterAtIndex:i];
        if (c < 'a' || c > 'p') return NO;
    }
    return YES;
}
NSString *LTWebStoreExtensionID(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (LTValidExtensionID(trimmed.lowercaseString)) return trimmed.lowercaseString;
    NSURLComponents *url = [NSURLComponents componentsWithString:trimmed];
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqual:@"https"] ||
        !([host isEqual:@"chromewebstore.google.com"] ||
          ([host isEqual:@"chrome.google.com"] && [url.path hasPrefix:@"/webstore/"])))
        return nil;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    if (![parts containsObject:@"detail"]) return nil;
    for (NSString *part in parts.reverseObjectEnumerator)
        if (LTValidExtensionID(part)) return part;
    return nil;
}
NSURL *LTWebStoreDownloadURL(NSString *identifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"https://clients2.google.com/service/update2/crx?response=redirect&prodversion=%@"
        @"&acceptformat=crx3&x=id%%3D%@%%26installsource%%3Dondemand%%26uc", ChromiumVersion, identifier]];
}
NSData *LTWebStorePublisherKeyHash(void) {
    // SHA-256 of the Chrome Web Store publisher key (Chromium crx_verifier.cc).
    static const uint8_t hash[] = {0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe,
                                   0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2,
                                   0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf};
    return [NSData dataWithBytes:hash length:sizeof hash];
}

#pragma mark - CRX3

static BOOL Varint(const uint8_t *bytes, size_t end, size_t *offset, uint64_t *value) {
    *value = 0;
    for (int shift = 0; shift < 64 && *offset < end; shift += 7) {
        uint8_t c = bytes[(*offset)++];
        *value |= (uint64_t)(c & 0x7f) << shift;
        if (!(c & 0x80)) return YES;
    }
    return NO;
}
// Visits length-delimited protobuf fields; other wire types are skipped.
static BOOL ProtoFields(NSData *data, void (^visit)(uint64_t field, NSData *value)) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length, offset = 0;
    while (offset < length) {
        uint64_t key, size;
        if (!Varint(bytes, length, &offset, &key)) return NO;
        switch (key & 7) {
            case 0: if (!Varint(bytes, length, &offset, &size)) return NO; continue;
            case 1: size = 8; break;
            case 5: size = 4; break;
            case 2: if (!Varint(bytes, length, &offset, &size)) return NO; break;
            default: return NO;
        }
        if (size > length - offset) return NO;
        if ((key & 7) == 2) visit(key >> 3, [data subdataWithRange:NSMakeRange(offset, size)]);
        offset += size;
    }
    return YES;
}
static BOOL DERElement(const uint8_t *bytes, size_t end, size_t *offset, uint8_t *tag, NSRange *content) {
    size_t i = *offset;
    if (i + 2 > end) return NO;
    *tag = bytes[i++];
    size_t size = bytes[i++];
    if (size & 0x80) {
        size_t count = size & 0x7f;
        if (!count || count > 4 || i + count > end) return NO;
        for (size = 0; count; count--) size = size << 8 | bytes[i++];
    }
    if (size > end - i) return NO;
    *content = NSMakeRange(i, size);
    *offset = i + size;
    return YES;
}
// Security.framework takes the raw key from inside a SubjectPublicKeyInfo.
static SecKeyRef CreatePublicKey(NSData *spki, BOOL ecdsa) {
    static const uint8_t rsa[] = {0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};
    static const uint8_t p256[] = {0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06,
                                   0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07};
    const uint8_t *bytes = spki.bytes;
    size_t offset = 0, inner;
    uint8_t tag;
    NSRange outer, algorithm, bits;
    if (!DERElement(bytes, spki.length, &offset, &tag, &outer) || tag != 0x30 || offset != spki.length)
        return NULL;
    inner = outer.location;
    size_t end = NSMaxRange(outer);
    if (!DERElement(bytes, end, &inner, &tag, &algorithm) || tag != 0x30 ||
        !DERElement(bytes, end, &inner, &tag, &bits) || tag != 0x03 || inner != end ||
        bits.length < 2 || bytes[bits.location] != 0)
        return NULL;
    const uint8_t *oid = ecdsa ? p256 : rsa;
    size_t oidLength = ecdsa ? sizeof p256 : sizeof rsa;
    if (algorithm.length < oidLength || memcmp(bytes + algorithm.location, oid, oidLength)) return NULL;
    NSData *key = [spki subdataWithRange:NSMakeRange(bits.location + 1, bits.length - 1)];
    NSDictionary *attributes = @{
        (id)kSecAttrKeyType : ecdsa ? (id)kSecAttrKeyTypeECSECPrimeRandom : (id)kSecAttrKeyTypeRSA,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic
    };
    return SecKeyCreateWithData((__bridge CFDataRef)key, (__bridge CFDictionaryRef)attributes, NULL);
}
NSData *LTVerifyCRX(NSData *crx, NSString *expectedID, NSData *requiredKeyHash, NSData **developerKey,
                    NSError **error) {
    const uint8_t *bytes = crx.bytes;
    if (crx.length < 12 || memcmp(bytes, "Cr24", 4))
        return FailNil(error, @"The file is not a Chrome extension package.");
    uint32_t version = OSReadLittleInt32(bytes, 4), headerSize = OSReadLittleInt32(bytes, 8);
    if (version != 3) return FailNil(error, @"Only CRX3 extension packages are supported.");
    if (headerSize > crx.length - 12) return FailNil(error, @"The extension package is truncated.");
    NSData *header = [crx subdataWithRange:NSMakeRange(12, headerSize)];
    NSData *archive = [crx subdataWithRange:NSMakeRange(12 + headerSize, crx.length - 12 - headerSize)];
    NSMutableArray<NSData *> *rsa = [NSMutableArray new], *ecdsa = [NSMutableArray new];
    __block NSData *signedData = nil, *crxID = nil;
    if (!ProtoFields(header, ^(uint64_t field, NSData *value) {
            if (field == 2) [rsa addObject:value];
            else if (field == 3) [ecdsa addObject:value];
            else if (field == 10000) signedData = value;
        }) || !signedData ||
        !ProtoFields(signedData, ^(uint64_t field, NSData *value) {
            if (field == 1) crxID = value;
        }) || crxID.length != 16)
        return FailNil(error, @"The extension package header is invalid.");
    NSMutableData *message = [NSMutableData dataWithBytes:"CRX3 SignedData" length:16];
    uint32_t signedLength = OSSwapHostToLittleInt32((uint32_t)signedData.length);
    [message appendBytes:&signedLength length:4];
    [message appendData:signedData];
    [message appendData:archive];
    // Like Chromium, every proof must verify, not just the ones Lite requires.
    NSData *developer = nil;
    BOOL required = requiredKeyHash == nil;
    for (NSArray<NSData *> *proofs in @[ rsa, ecdsa ])
        for (NSData *proof in proofs) {
            BOOL ec = proofs == ecdsa;
            __block NSData *key = nil, *signature = nil;
            if (!ProtoFields(proof, ^(uint64_t field, NSData *value) {
                    if (field == 1) key = value;
                    else if (field == 2) signature = value;
                }) || !key || !signature)
                return FailNil(error, @"The extension package header is invalid.");
            SecKeyRef secKey = CreatePublicKey(key, ec);
            BOOL valid = secKey && SecKeyVerifySignature(secKey,
                ec ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256 : kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                (__bridge CFDataRef)message, (__bridge CFDataRef)signature, NULL);
            if (secKey) CFRelease(secKey);
            if (!valid) return FailNil(error, @"An extension package signature is invalid.");
            NSData *hash = SHA256(key);
            if (!memcmp(hash.bytes, crxID.bytes, 16)) developer = key;
            if ([hash isEqual:requiredKeyHash]) required = YES;
        }
    if (!developer) return FailNil(error, @"The extension package is not signed by its developer key.");
    if (!required) return FailNil(error, @"The extension package is not signed by the Chrome Web Store.");
    if (expectedID && ![LTExtensionIDForKey(developer) isEqual:expectedID])
        return FailNil(error, @"The package contains a different extension than the one requested.");
    if (archive.length < 4 || memcmp(archive.bytes, "PK\x03\x04", 4))
        return FailNil(error, @"The extension package archive is invalid.");
    if (developerKey) *developerKey = developer;
    return archive;
}

#pragma mark - Manifests

static NSDictionary *ReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingJSON5Allowed error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSString *Contained(NSString *directory, id relative) {
    if (![relative isKindOfClass:NSString.class] || ![relative length]) return nil;
    // Standardize both sides: it also drops a leading /private from existing paths.
    NSString *base = directory.stringByStandardizingPath;
    NSString *path = [base stringByAppendingPathComponent:relative].stringByStandardizingPath;
    return [path hasPrefix:[base stringByAppendingString:@"/"]] &&
        [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}
static NSString *Localized(id value, NSString *directory, NSDictionary *manifest) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    if (text.length <= 8 || ![text hasPrefix:@"__MSG_"] || ![text hasSuffix:@"__"]) return text;
    NSString *key = [text substringWithRange:NSMakeRange(6, text.length - 8)].lowercaseString;
    NSMutableArray<NSString *> *locales = [NSMutableArray new];
    NSString *preferred = [NSLocale.preferredLanguages.firstObject stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if (preferred) [locales addObjectsFromArray:@[ preferred, [preferred componentsSeparatedByString:@"_"].firstObject ]];
    if ([manifest[@"default_locale"] isKindOfClass:NSString.class]) [locales addObject:manifest[@"default_locale"]];
    for (NSString *locale in locales) {
        NSString *file = Contained(directory, [NSString stringWithFormat:@"_locales/%@/messages.json", locale]);
        NSDictionary *messages = file ? ReadJSON(file) : nil;
        for (NSString *name in messages)
            if ([name.lowercaseString isEqual:key] && [messages[name] isKindOfClass:NSDictionary.class] &&
                [messages[name][@"message"] isKindOfClass:NSString.class])
                return messages[name][@"message"];
    }
    return text;
}
static NSString *IconPath(NSDictionary *manifest, NSString *directory) {
    id icons = manifest[@"icons"];
    NSDictionary *action = [manifest[@"action"] isKindOfClass:NSDictionary.class] ? manifest[@"action"] : nil;
    if (![icons isKindOfClass:NSDictionary.class])
        icons = [action[@"default_icon"] isKindOfClass:NSString.class] ? @{@"16" : action[@"default_icon"]} : action[@"default_icon"];
    if (![icons isKindOfClass:NSDictionary.class]) return nil;
    NSString *best = nil;
    NSInteger size = 0;
    for (NSString *key in icons) {
        NSString *path = Contained(directory, icons[key]);
        if (path && key.integerValue > size) { best = path; size = key.integerValue; }
    }
    return best;
}
static NSArray<NSString *> *Warnings(NSDictionary *manifest) {
    NSMutableOrderedSet *hosts = [NSMutableOrderedSet new], *warnings = [NSMutableOrderedSet new];
    NSMutableArray *patterns = [NSMutableArray new];
    for (NSString *key in @[ @"permissions", @"host_permissions" ])
        if ([manifest[key] isKindOfClass:NSArray.class]) [patterns addObjectsFromArray:manifest[key]];
    if ([manifest[@"content_scripts"] isKindOfClass:NSArray.class])
        for (NSDictionary *script in manifest[@"content_scripts"])
            if ([script isKindOfClass:NSDictionary.class] && [script[@"matches"] isKindOfClass:NSArray.class])
                [patterns addObjectsFromArray:script[@"matches"]];
    NSDictionary *apis = @{
        @"bookmarks" : @"Read and change your bookmarks", @"clipboardRead" : @"Read data you copy and paste",
        @"debugger" : @"Access the page debugger backend", @"declarativeNetRequest" : @"Block content on any page",
        @"downloads" : @"Manage your downloads", @"geolocation" : @"Detect your physical location",
        @"history" : @"Read and change your browsing history", @"management" : @"Manage your apps, extensions, and themes",
        @"nativeMessaging" : @"Communicate with cooperating native applications",
        @"notifications" : @"Display notifications", @"privacy" : @"Change your privacy-related settings",
        @"proxy" : @"Change proxy settings", @"tabs" : @"Read your browsing history",
        @"topSites" : @"Read a list of your most frequently visited websites", @"webNavigation" : @"Read your browsing history"
    };
    BOOL allSites = NO;
    for (id pattern in patterns) {
        if (![pattern isKindOfClass:NSString.class]) continue;
        if (apis[pattern]) { [warnings addObject:apis[pattern]]; continue; }
        NSRange scheme = [pattern rangeOfString:@"://"];
        if ([pattern isEqual:@"<all_urls>"]) { allSites = YES; continue; }
        if (scheme.location == NSNotFound) continue;
        NSString *host = [[pattern substringFromIndex:NSMaxRange(scheme)] componentsSeparatedByString:@"/"].firstObject;
        if ([host isEqual:@"*"]) allSites = YES;
        else if (host.length) [hosts addObject:[host hasPrefix:@"*."] ? [host substringFromIndex:2] : host];
    }
    if (allSites) [warnings insertObject:@"Read and change all your data on all websites" atIndex:0];
    else if (hosts.count)
        [warnings insertObject:[@"Read and change your data on " stringByAppendingString:
            [hosts.array componentsJoinedByString:@", "]] atIndex:0];
    return warnings.array;
}
static NSDictionary *ManifestInfo(NSString *directory, NSString **problem) {
    NSDictionary *manifest = ReadJSON([directory stringByAppendingPathComponent:@"manifest.json"]);
    if (!manifest) { *problem = @"The folder has no valid manifest.json."; return nil; }
    if (![manifest[@"manifest_version"] isEqual:@3]) {
        *problem = @"Lite runs Manifest V3 extensions. Chromium no longer loads Manifest V2 extensions.";
        return nil;
    }
    if (manifest[@"theme"]) { *problem = @"Themes change Chrome’s own interface, which Lite does not use."; return nil; }
    if (manifest[@"app"]) { *problem = @"Chrome Apps are not supported."; return nil; }
    NSString *name = Localized(manifest[@"name"], directory, manifest);
    if (!name.length || ![manifest[@"version"] isKindOfClass:NSString.class]) {
        *problem = @"The manifest has no name or version.";
        return nil;
    }
    NSMutableDictionary *info = [@{@"name" : name, @"version" : manifest[@"version"],
        @"summary" : Localized(manifest[@"description"], directory, manifest)} mutableCopy];
    if (manifest[@"key"]) {
        NSData *key = [manifest[@"key"] isKindOfClass:NSString.class] ? [[NSData alloc]
            initWithBase64EncodedString:manifest[@"key"] options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
        if (!key.length) { *problem = @"The manifest key is invalid."; return nil; }
        info[@"key"] = key;
    }
    NSDictionary *action = [manifest[@"action"] isKindOfClass:NSDictionary.class] ? manifest[@"action"] : nil;
    NSDictionary *optionsUI = [manifest[@"options_ui"] isKindOfClass:NSDictionary.class] ? manifest[@"options_ui"] : nil;
    if (Contained(directory, action[@"default_popup"])) info[@"popup"] = action[@"default_popup"];
    for (id page in @[ optionsUI[@"page"] ?: NSNull.null, manifest[@"options_page"] ?: NSNull.null ])
        if (!info[@"options"] && Contained(directory, page)) info[@"options"] = page;
    info[@"icon"] = IconPath(manifest, directory);
    info[@"warnings"] = Warnings(manifest);
    return info;
}
static NSString *RealPath(NSString *path) {
    char buffer[PATH_MAX];
    return realpath(path.fileSystemRepresentation, buffer) ? @(buffer) : nil;
}

#pragma mark - Registry

@interface LTExtension ()
@property (nonatomic, readwrite) NSString *identifier, *path, *source, *name, *version, *summary;
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, readwrite, nullable) NSString *popup, *options, *iconPath, *problem;
@property (nonatomic, readwrite) NSArray<NSString *> *warnings;
@end
@implementation LTExtension
- (NSString *)URLForPage:(NSString *)page {
    if (!page.length) return nil;
    return [NSString stringWithFormat:@"chrome-extension://%@/%@", _identifier,
            [page hasPrefix:@"/"] ? [page substringFromIndex:1] : page];
}
@end

@implementation LTExtensions {
    NSString *_registry;
    NSMutableArray<NSDictionary *> *_records;
    NSDictionary<NSString *, NSString *> *_launchedPaths;
    NSURLSession *_session;
}
- (instancetype)initWithProfilePath:(NSString *)profile {
    if ((self = [super init])) {
        _directory = [profile stringByAppendingPathComponent:@"Extensions"];
        _registry = [_directory stringByAppendingPathComponent:@"Extensions.json"];
        _records = [NSMutableArray new];
        _launched = @[];
        id saved = ReadJSON(_registry)[@"extensions"];
        for (NSDictionary *record in [saved isKindOfClass:NSArray.class] ? saved : @[])
            if ([self validRecord:record])
                [_records addObject:@{@"id" : record[@"id"], @"path" : record[@"path"],
                                      @"source" : record[@"source"], @"enabled" : @([record[@"enabled"] boolValue])}];
        [self collectGarbage];
        [self reload];
    }
    return self;
}
- (BOOL)validRecord:(NSDictionary *)record {
    if (![record isKindOfClass:NSDictionary.class] || !LTValidExtensionID(record[@"id"]) ||
        ![record[@"path"] isKindOfClass:NSString.class] || [self recordFor:record[@"id"]])
        return NO;
    NSString *path = record[@"path"];
    if ([record[@"source"] isEqual:@"webstore"]) {
        NSArray *parts = path.pathComponents;
        return parts.count == 2 && [parts[0] isEqual:record[@"id"]] && ![parts[1] hasPrefix:@"."];
    }
    return [record[@"source"] isEqual:@"unpacked"] && path.absolutePath && ![path containsString:@","];
}
- (NSDictionary *)recordFor:(NSString *)identifier {
    for (NSDictionary *record in _records)
        if ([record[@"id"] isEqual:identifier]) return record;
    return nil;
}
// Chromium reads installed files lazily, so replaced or removed Web Store
// versions are deleted only here, before the engine starts.
- (void)collectGarbage {
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in [files contentsOfDirectoryAtPath:_directory error:nil]) {
        NSString *path = [_directory stringByAppendingPathComponent:name];
        if ([name hasPrefix:@".staging-"]) { [files removeItemAtPath:path error:nil]; continue; }
        if (!LTValidExtensionID(name)) continue;
        NSDictionary *record = [self recordFor:name];
        NSString *current = [record[@"source"] isEqual:@"webstore"] ? [record[@"path"] lastPathComponent] : nil;
        if (!current) { [files removeItemAtPath:path error:nil]; continue; }
        for (NSString *version in [files contentsOfDirectoryAtPath:path error:nil])
            if (![version isEqual:current]) [files removeItemAtPath:[path stringByAppendingPathComponent:version] error:nil];
    }
}
- (void)reload {
    NSMutableArray *extensions = [NSMutableArray new];
    for (NSDictionary *record in _records) {
        LTExtension *extension = [LTExtension new];
        extension.identifier = record[@"id"];
        extension.source = record[@"source"];
        extension.enabled = [record[@"enabled"] boolValue];
        BOOL webStore = [extension.source isEqual:@"webstore"];
        extension.path = webStore ? [_directory stringByAppendingPathComponent:record[@"path"]] : record[@"path"];
        BOOL directory = NO;
        NSString *problem = nil;
        NSDictionary *info = nil;
        if (![NSFileManager.defaultManager fileExistsAtPath:extension.path isDirectory:&directory] || !directory)
            problem = webStore ? @"The installed files are missing. Install the extension again." :
                                 @"The extension folder was moved or deleted.";
        else if ((info = ManifestInfo(extension.path, &problem))) {
            NSString *actual = info[@"key"] ? LTExtensionIDForKey(info[@"key"]) : LTExtensionIDForPath(extension.path);
            if (![actual isEqual:extension.identifier]) {
                problem = @"The extension’s manifest key changed. Remove it and add it again.";
                info = nil;
            }
        }
        extension.name = info[@"name"] ?: webStore ? extension.identifier : extension.path.lastPathComponent;
        extension.version = info[@"version"] ?: @"";
        extension.summary = info[@"summary"] ?: @"";
        extension.popup = info[@"popup"];
        extension.options = info[@"options"];
        extension.iconPath = info[@"icon"];
        extension.warnings = info[@"warnings"] ?: @[];
        extension.problem = info ? nil : problem;
        [extensions addObject:extension];
    }
    _extensions = extensions;
}
- (NSDictionary<NSString *, NSString *> *)loadablePaths {
    NSMutableDictionary *paths = [NSMutableDictionary new];
    for (LTExtension *extension in _extensions)
        if (extension.enabled && !extension.problem) paths[extension.identifier] = extension.path;
    return paths;
}
- (NSString *)launchSwitch {
    _launchedPaths = [self loadablePaths];
    NSMutableArray *launched = [NSMutableArray new], *paths = [NSMutableArray new];
    for (LTExtension *extension in _extensions)
        if (_launchedPaths[extension.identifier]) {
            [launched addObject:extension];
            [paths addObject:extension.path];
        }
    _launched = launched;
    return [paths componentsJoinedByString:@","];
}
- (BOOL)restartRequired {
    return _launchedPaths && ![[self loadablePaths] isEqual:_launchedPaths];
}
- (LTExtension *)extensionWithIdentifier:(NSString *)identifier {
    for (LTExtension *extension in _extensions)
        if ([extension.identifier isEqual:identifier]) return extension;
    return nil;
}
- (BOOL)commit:(void (^)(NSMutableArray<NSDictionary *> *records))change error:(NSError **)error {
    NSArray *previous = [_records copy];
    change(_records);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version" : @1, @"extensions" : _records}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!data || ![NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions : @0700} error:error] ||
        ![data writeToFile:_registry options:NSDataWritingAtomic error:error]) {
        [_records setArray:previous];
        return NO;
    }
    [self reload];
    [NSNotificationCenter.defaultCenter postNotificationName:LTExtensionsChanged object:self];
    return YES;
}
- (LTExtension *)addUnpackedAtPath:(NSString *)path error:(NSError **)error {
    NSString *real = RealPath(path);
    BOOL directory = NO;
    if (!real || ![NSFileManager.defaultManager fileExistsAtPath:real isDirectory:&directory] || !directory)
        return FailNil(error, @"The extension folder could not be opened.");
    if ([real containsString:@","])
        return FailNil(error, @"Chromium cannot load an extension from a folder whose path contains a comma. Rename or move the folder.");
    NSString *managed = RealPath(_directory);
    if (managed && [[real stringByAppendingString:@"/"] hasPrefix:[managed stringByAppendingString:@"/"]])
        return FailNil(error, @"Choose an extension folder outside Lite’s profile.");
    NSString *problem = nil;
    NSDictionary *info = ManifestInfo(real, &problem);
    if (!info) return FailNil(error, problem);
    NSString *identifier = info[@"key"] ? LTExtensionIDForKey(info[@"key"]) : LTExtensionIDForPath(real);
    if ([self recordFor:identifier])
        return FailNil(error, [NSString stringWithFormat:@"“%@” is already added.", info[@"name"]]);
    if (![self commit:^(NSMutableArray *records) {
            [records addObject:@{@"id" : identifier, @"path" : real, @"source" : @"unpacked", @"enabled" : @YES}];
        } error:error])
        return nil;
    return [self extensionWithIdentifier:identifier];
}
- (BOOL)extractArchive:(NSData *)archive into:(NSString *)destination error:(NSError **)error {
    NSString *zip = [destination.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"package.zip"];
    if (![archive writeToFile:zip options:NSDataWritingAtomic error:error]) return NO;
    // Info-ZIP strips absolute and "../" member paths; -o avoids interactive prompts.
    NSTask *unzip = [NSTask new];
    unzip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
    unzip.arguments = @[ @"-qq", @"-o", zip, @"-d", destination ];
    unzip.standardInput = NSFileHandle.fileHandleWithNullDevice;
    unzip.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    unzip.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![unzip launchAndReturnError:error]) return NO;
    [unzip waitUntilExit];
    if (unzip.terminationStatus != 0) {
        if (error) *error = Failure(@"The extension archive could not be extracted.");
        return NO;
    }
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:destination];
    for (NSString *item in walk)
        if (![@[ NSFileTypeRegular, NSFileTypeDirectory ] containsObject:walk.fileAttributes.fileType]) {
            if (error) *error = Failure([NSString stringWithFormat:@"The extension archive contains an unsupported item: %@", item]);
            return NO;
        }
    return YES;
}
// Unpacks a verified archive and moves it to Extensions/<id>/<version>/.
- (NSString *)stageArchive:(NSData *)archive key:(NSData *)key identifier:(NSString *)identifier
                   staging:(NSString *)staging error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *unpacked = [staging stringByAppendingPathComponent:@"files"];
    if (![files createDirectoryAtPath:unpacked withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:error] ||
        ![self extractArchive:archive into:unpacked error:error])
        return nil;
    NSString *problem = nil;
    NSDictionary *info = ManifestInfo(unpacked, &problem);
    if (!info) return FailNil(error, problem);
    if (info[@"key"] && ![LTExtensionIDForKey(info[@"key"]) isEqual:identifier])
        return FailNil(error, @"The package manifest names a different extension key.");
    // The key keeps the Web Store ID when Chromium loads the files as an unpacked extension.
    NSString *manifestPath = [unpacked stringByAppendingPathComponent:@"manifest.json"];
    NSMutableDictionary *manifest = [ReadJSON(manifestPath) mutableCopy];
    manifest[@"key"] = [key base64EncodedStringWithOptions:0];
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    NSString *version = NSUUID.UUID.UUIDString;
    NSString *destination = [[_directory stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:version];
    if (!data || ![data writeToFile:manifestPath options:NSDataWritingAtomic error:error] ||
        ![files createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions : @0700} error:error] ||
        ![files moveItemAtPath:unpacked toPath:destination error:error])
        return nil;
    return version;
}
- (LTExtension *)installPackage:(NSData *)crx identifier:(NSString *)identifier
                requiredKeyHash:(NSData *)requiredKeyHash error:(NSError **)error {
    NSDictionary *existing = [self recordFor:identifier];
    if ([existing[@"source"] isEqual:@"unpacked"])
        return FailNil(error, @"This extension is already added from a folder. Remove that copy first.");
    NSData *key = nil;
    NSData *archive = LTVerifyCRX(crx, identifier, requiredKeyHash, &key, error);
    if (!archive) return nil;
    NSString *staging = [_directory stringByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *version = [self stageArchive:archive key:key identifier:identifier staging:staging error:error];
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    if (!version) return nil;
    NSString *path = [identifier stringByAppendingPathComponent:version];
    // An unchanged version keeps the loaded copy, so no restart is needed.
    LTExtension *current = [self extensionWithIdentifier:identifier];
    NSString *downloaded = ReadJSON([[_directory stringByAppendingPathComponent:path] stringByAppendingPathComponent:@"manifest.json"])[@"version"];
    if (current && !current.problem && [current.version isEqual:downloaded]) {
        [NSFileManager.defaultManager removeItemAtPath:[_directory stringByAppendingPathComponent:path] error:nil];
        return current;
    }
    if (![self commit:^(NSMutableArray<NSDictionary *> *records) {
            NSDictionary *record = @{@"id" : identifier, @"path" : path, @"source" : @"webstore",
                                     @"enabled" : existing ? existing[@"enabled"] : @YES};
            NSUInteger index = existing ? [records indexOfObject:existing] : NSNotFound;
            if (index != NSNotFound) records[index] = record;
            else [records addObject:record];
        } error:error]) {
        [NSFileManager.defaultManager removeItemAtPath:[_directory stringByAppendingPathComponent:path] error:nil];
        return nil;
    }
    return [self extensionWithIdentifier:identifier];
}
- (void)installFromWebStore:(NSString *)identifier
                 completion:(void (^)(LTExtension *, NSError *))completion {
    if (!LTValidExtensionID(identifier)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, Failure(@"Enter a Chrome Web Store link or a 32-letter extension ID."));
        });
        return;
    }
    if (!_session) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 60;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    [[_session dataTaskWithURL:LTWebStoreDownloadURL(identifier)
             completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (networkError) {
                completion(nil, Failure([@"The Chrome Web Store could not be reached. " stringByAppendingString:networkError.localizedDescription]));
                return;
            }
            if (http.statusCode != 200 || ![http.URL.scheme isEqual:@"https"] || !data.length || data.length > MaximumPackageSize) {
                completion(nil, Failure(@"The Chrome Web Store did not provide this extension. It may have been removed, or it may be a theme or an app."));
                return;
            }
            NSError *error = nil;
            LTExtension *extension = [self installPackage:data identifier:identifier
                                          requiredKeyHash:LTWebStorePublisherKeyHash() error:&error];
            completion(extension, error);
        });
    }] resume];
}
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSError **)error {
    NSDictionary *record = [self recordFor:identifier];
    if (!record) { if (error) *error = Failure(@"The extension is no longer installed."); return NO; }
    return [self commit:^(NSMutableArray<NSDictionary *> *records) {
        NSMutableDictionary *updated = [record mutableCopy];
        updated[@"enabled"] = @(enabled);
        records[[records indexOfObject:record]] = updated;
    } error:error];
}
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error {
    NSDictionary *record = [self recordFor:identifier];
    if (!record) return YES;
    return [self commit:^(NSMutableArray<NSDictionary *> *records) {
        [records removeObject:record];
    } error:error];
}
@end
