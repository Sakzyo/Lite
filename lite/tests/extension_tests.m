#import "../model/LTExtensions.h"
#import "../model/LTModel.h"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static int failures;
#define CHECK(c, name) do { if (!(c)) { fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); failures++; } \
    else printf("PASS %s\n", name); } while (0)

static NSData *DER(uint8_t tag, NSData *content) {
    NSMutableData *data = [NSMutableData dataWithBytes:&tag length:1];
    NSUInteger length = content.length;
    if (length < 128) {
        uint8_t size = length;
        [data appendBytes:&size length:1];
    } else {
        uint8_t size[] = {0x82, length >> 8, length & 0xff};
        [data appendBytes:size length:3];
    }
    [data appendData:content];
    return data;
}
static NSData *Concat(NSArray<NSData *> *parts) {
    NSMutableData *data = [NSMutableData new];
    for (NSData *part in parts) [data appendData:part];
    return data;
}
static NSData *Bytes(const void *bytes, size_t length) { return [NSData dataWithBytes:bytes length:length]; }
// Synthetic keys only: generated in memory for each run, never stored in Keychain.
static SecKeyRef NewKey(BOOL ec) {
    NSDictionary *attributes = @{(id)kSecAttrKeyType : ec ? (id)kSecAttrKeyTypeECSECPrimeRandom : (id)kSecAttrKeyTypeRSA,
                                 (id)kSecAttrKeySizeInBits : ec ? @256 : @2048};
    return SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, NULL);
}
static NSData *SPKI(SecKeyRef privateKey, BOOL ec) {
    SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
    NSData *raw = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL));
    CFRelease(publicKey);
    static const uint8_t rsa[] = {0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00};
    static const uint8_t p256[] = {0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06,
                                   0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07};
    uint8_t unused = 0;
    NSData *algorithm = DER(0x30, ec ? Bytes(p256, sizeof p256) : Bytes(rsa, sizeof rsa));
    return DER(0x30, Concat(@[ algorithm, DER(0x03, Concat(@[ Bytes(&unused, 1), raw ])) ]));
}
static NSData *Varint(uint64_t value) {
    NSMutableData *data = [NSMutableData new];
    do {
        uint8_t byte = (value & 0x7f) | (value > 0x7f ? 0x80 : 0);
        [data appendBytes:&byte length:1];
        value >>= 7;
    } while (value);
    return data;
}
static NSData *Field(uint64_t field, NSData *value) {
    return Concat(@[ Varint(field << 3 | 2), Varint(value.length), value ]);
}
static NSData *Hash(NSData *data) {
    NSMutableData *digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest.mutableBytes);
    return digest;
}
static NSData *Zip(NSString *directory, NSDictionary *manifest) {
    NSString *root = [directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil]
        writeToFile:[root stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    [@"<!doctype html><title>Popup</title>" writeToFile:[root stringByAppendingPathComponent:@"popup.html"]
                                            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSTask *zip = [NSTask new];
    zip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/zip"];
    zip.currentDirectoryURL = [NSURL fileURLWithPath:root];
    NSString *output = [root stringByAppendingPathExtension:@"zip"];
    zip.arguments = @[ @"-q", @"-r", output, @"." ];
    [zip launchAndReturnError:nil];
    [zip waitUntilExit];
    return [NSData dataWithContentsOfFile:output];
}
// Builds a CRX3 the way Chromium's crx_creator does: every proof signs the same message.
static NSData *CRX(NSData *archive, SecKeyRef developer, SecKeyRef publisher) {
    NSData *developerKey = SPKI(developer, NO);
    NSData *signedData = Field(1, [Hash(developerKey) subdataWithRange:NSMakeRange(0, 16)]);
    uint32_t length = OSSwapHostToLittleInt32((uint32_t)signedData.length);
    NSData *message = Concat(@[ Bytes("CRX3 SignedData", 16), Bytes(&length, 4), signedData, archive ]);
    NSData *(^proof)(SecKeyRef, BOOL) = ^NSData *(SecKeyRef key, BOOL ec) {
        NSData *signature = CFBridgingRelease(SecKeyCreateSignature(key,
            ec ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256 : kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
            (__bridge CFDataRef)message, NULL));
        return Concat(@[ Field(1, SPKI(key, ec)), Field(2, signature) ]);
    };
    NSMutableData *header = [Field(2, proof(developer, NO)) mutableCopy];
    if (publisher) [header appendData:Field(3, proof(publisher, YES))];
    [header appendData:Field(10000, signedData)];
    uint32_t version = OSSwapHostToLittleInt32(3), size = OSSwapHostToLittleInt32((uint32_t)header.length);
    return Concat(@[ Bytes("Cr24", 4), Bytes(&version, 4), Bytes(&size, 4), header, archive ]);
}
static NSString *Unpacked(NSString *directory, NSString *name, NSDictionary *manifest) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil]
        writeToFile:[path stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    return path;
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [@"LiteExtensionTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *work = [root stringByAppendingPathComponent:@"work"], *profile = [root stringByAppendingPathComponent:@"profile"];
        [NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];

        CHECK([LTExtensionIDForPath(@"/tmp/lite-extension") isEqual:@"nnhmhbfceimolobekbmoakhmlmlpibcd"], "unpacked ID matches Chromium");
        CHECK(LTValidExtensionID(@"ddkjiahejlhfcafbddmgiahcphecmpfh") && !LTValidExtensionID(@"ddkjiahejlhfcafbddmgiahcphecmpfz") &&
              !LTValidExtensionID(@"short"), "extension ID validation");
        CHECK([LTWebStoreExtensionID(@"https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en")
               isEqual:@"ddkjiahejlhfcafbddmgiahcphecmpfh"] &&
              [LTWebStoreExtensionID(@"https://chrome.google.com/webstore/detail/x/ddkjiahejlhfcafbddmgiahcphecmpfh")
               isEqual:@"ddkjiahejlhfcafbddmgiahcphecmpfh"] &&
              [LTWebStoreExtensionID(@" DDKJIAHEJLHFCAFBDDMGIAHCPHECMPFH ") isEqual:@"ddkjiahejlhfcafbddmgiahcphecmpfh"],
              "Web Store links and IDs parse");
        CHECK(!LTWebStoreExtensionID(@"https://example.org/detail/x/ddkjiahejlhfcafbddmgiahcphecmpfh") &&
              !LTWebStoreExtensionID(@"http://chromewebstore.google.com/detail/x/ddkjiahejlhfcafbddmgiahcphecmpfh") &&
              !LTWebStoreExtensionID(@"https://chromewebstore.google.com/category/extensions"),
              "non-Web Store links are rejected");
        CHECK([LTWebStoreDownloadURL(@"ddkjiahejlhfcafbddmgiahcphecmpfh").absoluteString
               containsString:@"x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26installsource%3Dondemand%26uc"],
              "Web Store download URL");
        CHECK(LTValidURL(@"chrome-extension://ddkjiahejlhfcafbddmgiahcphecmpfh/popup.html") &&
              !LTValidURL(@"chrome-extension://not-an-id/popup.html"), "extension pages are valid tab URLs");

        SecKeyRef developer = NewKey(NO), publisher = NewKey(YES), other = NewKey(YES);
        NSData *publisherHash = Hash(SPKI(publisher, YES));
        NSString *identifier = LTExtensionIDForKey(SPKI(developer, NO));
        NSDictionary *manifest = @{@"manifest_version" : @3, @"name" : @"Synthetic Extension", @"version" : @"1.0",
                                   @"action" : @{@"default_popup" : @"popup.html"},
                                   @"content_scripts" : @[ @{@"matches" : @[ @"<all_urls>" ], @"js" : @[ @"x.js" ]} ],
                                   @"permissions" : @[ @"tabs", @"storage" ]};
        NSData *crx = CRX(Zip(work, manifest), developer, publisher);
        NSError *error = nil;
        NSData *key = nil;
        CHECK(LTVerifyCRX(crx, identifier, publisherHash, &key, &error) && [key isEqual:SPKI(developer, NO)],
              "CRX3 RSA developer and ECDSA publisher proofs verify");
        CHECK(!LTVerifyCRX(crx, identifier, Hash(SPKI(other, YES)), nil, &error), "missing publisher proof is rejected");
        CHECK(!LTVerifyCRX(CRX(Zip(work, manifest), developer, nil), identifier, publisherHash, nil, &error),
              "unsigned-by-publisher package is rejected");
        CHECK(!LTVerifyCRX(crx, @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nil, nil, &error), "package for another ID is rejected");
        NSMutableData *tampered = [crx mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[tampered.length - 30] ^= 0x40;
        CHECK(!LTVerifyCRX(tampered, identifier, nil, nil, &error) &&
              [error.localizedDescription containsString:@"signature"], "tampered archive is rejected");
        CHECK(!LTVerifyCRX([@"Cr24" dataUsingEncoding:NSUTF8StringEncoding], nil, nil, nil, &error) &&
              !LTVerifyCRX([crx subdataWithRange:NSMakeRange(0, 40)], nil, nil, nil, &error), "truncated packages are rejected");

        LTExtensions *extensions = [[LTExtensions alloc] initWithProfilePath:profile];
        LTExtension *installed = [extensions installPackage:crx identifier:identifier requiredKeyHash:publisherHash error:&error];
        NSDictionary *written = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
            [installed.path stringByAppendingPathComponent:@"manifest.json"]] options:0 error:nil];
        CHECK(installed && [installed.name isEqual:@"Synthetic Extension"] && [installed.popup isEqual:@"popup.html"] &&
              !installed.problem && [installed.source isEqual:@"webstore"], "verified package installs");
        CHECK([[[NSData alloc] initWithBase64EncodedString:written[@"key"] options:0] isEqual:SPKI(developer, NO)],
              "installed manifest keeps the Web Store ID");
        CHECK([installed.warnings.firstObject isEqual:@"Read and change all your data on all websites"] &&
              [installed.warnings containsObject:@"Read your browsing history"], "permission warnings");
        NSString *popupURL = [NSString stringWithFormat:@"chrome-extension://%@/popup.html", identifier];
        CHECK([[installed URLForPage:installed.popup] isEqual:popupURL], "extension page URL");
        NSString *launch = extensions.launchSwitch;
        CHECK([launch isEqual:installed.path] && extensions.launched.count == 1 && !extensions.restartRequired,
              "launch switch lists enabled extensions");
        LTExtension *again = [extensions installPackage:crx identifier:identifier requiredKeyHash:publisherHash error:&error];
        CHECK([again.path isEqual:installed.path] && !extensions.restartRequired, "same version keeps the loaded copy");
        NSMutableDictionary *newer = [manifest mutableCopy];
        newer[@"version"] = @"1.1";
        LTExtension *updated = [extensions installPackage:CRX(Zip(work, newer), developer, publisher) identifier:identifier
                                          requiredKeyHash:publisherHash error:&error];
        CHECK([updated.version isEqual:@"1.1"] && ![updated.path isEqual:installed.path] && extensions.restartRequired &&
              [NSFileManager.defaultManager fileExistsAtPath:installed.path], "update installs beside the running version");
        CHECK([extensions setEnabled:NO identifier:identifier error:&error] && ![extensions extensionWithIdentifier:identifier].enabled,
              "extension can be turned off");

        NSString *folder = Unpacked(work, @"Unpacked", @{@"manifest_version" : @3, @"name" : @"__MSG_name__",
                                                         @"version" : @"2", @"default_locale" : @"en",
                                                         @"options_page" : @"manifest.json"});
        [NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"_locales/en"]
                                withIntermediateDirectories:YES attributes:nil error:nil];
        [@"{\"name\":{\"message\":\"Localized Name\"}}" writeToFile:[folder stringByAppendingPathComponent:@"_locales/en/messages.json"]
                                                         atomically:YES encoding:NSUTF8StringEncoding error:nil];
        LTExtension *unpacked = [extensions addUnpackedAtPath:folder error:&error];
        char real[PATH_MAX];
        realpath(folder.fileSystemRepresentation, real);
        CHECK(unpacked && [unpacked.identifier isEqual:LTExtensionIDForPath(@(real))] &&
              [unpacked.name isEqual:@"Localized Name"] && [unpacked.options isEqual:@"manifest.json"],
              "unpacked folder adds with its path ID and localized name");
        CHECK(![extensions addUnpackedAtPath:folder error:&error] && [error.localizedDescription containsString:@"already"],
              "duplicate folder is rejected");
        CHECK(![extensions addUnpackedAtPath:Unpacked(work, @"Old", @{@"manifest_version" : @2, @"name" : @"Old", @"version" : @"1"})
                                      error:&error] && [error.localizedDescription containsString:@"Manifest V3"],
              "Manifest V2 is rejected");
        CHECK(![extensions addUnpackedAtPath:Unpacked(work, @"a,b", @{@"manifest_version" : @3, @"name" : @"Comma", @"version" : @"1"})
                                      error:&error] && [error.localizedDescription containsString:@"comma"],
              "comma paths are rejected");
        CHECK(![extensions addUnpackedAtPath:installed.path error:&error], "managed copies cannot be re-added as folders");

        LTExtensions *reopened = [[LTExtensions alloc] initWithProfilePath:profile];
        CHECK(reopened.extensions.count == 2 && [[reopened extensionWithIdentifier:identifier].version isEqual:@"1.1"] &&
              ![reopened extensionWithIdentifier:identifier].enabled && [reopened.launchSwitch isEqual:@(real)],
              "registry persists and skips disabled extensions");
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:installed.path] &&
              [NSFileManager.defaultManager fileExistsAtPath:updated.path], "replaced version is deleted at next launch");
        CHECK([reopened removeIdentifier:identifier error:&error] && [reopened removeIdentifier:unpacked.identifier error:&error] &&
              [NSFileManager.defaultManager fileExistsAtPath:updated.path] && [NSFileManager.defaultManager fileExistsAtPath:folder] &&
              reopened.restartRequired, "removal waits for restart and keeps user folders");
        LTExtensions *restarted = [[LTExtensions alloc] initWithProfilePath:profile];
        CHECK(!restarted.extensions.count && ![NSFileManager.defaultManager fileExistsAtPath:updated.path.stringByDeletingLastPathComponent] &&
              [NSFileManager.defaultManager fileExistsAtPath:folder] && !restarted.launchSwitch.length,
              "removed Web Store files are deleted at next launch");

        CFRelease(developer);
        CFRelease(publisher);
        CFRelease(other);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    return failures ? 1 : 0;
}
