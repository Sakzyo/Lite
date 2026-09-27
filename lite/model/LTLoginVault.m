#import "LTLoginVault.h"
#import "LTLoginStore.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>
#include <sys/acl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const char Header[8] = {'L', 'I', 'T', 'E', 'V', 'L', 'T', 1};
static const NSUInteger MaxSize = 16 * 1024 * 1024;
static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"LiteLoginVault" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static BOOL IOFail(NSError **error) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
}
static BOOL KeychainStatus(OSStatus status, NSError **error) {
    if (status == errSecSuccess) return YES;
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{
        NSLocalizedDescriptionKey: CFBridgingRelease(SecCopyErrorMessageString(status, NULL))
            ?: @"The vault key could not be accessed in Keychain. The vault was preserved."}];
    return NO;
}
static BOOL Protect(int fd, BOOL directory, NSError **error) {
    struct stat st;
    if (fstat(fd, &st)) return IOFail(error);
    if (st.st_uid != getuid() || (directory ? !S_ISDIR(st.st_mode)
                                         : (!S_ISREG(st.st_mode) || st.st_nlink != 1)))
        return Fail(error, @"The vault must be an ordinary file owned by your macOS account.");
    // Mode bits alone do not remove inherited macOS ACL grants.
    acl_t empty = acl_init(0);
    if (!empty) return IOFail(error);
    int result = acl_set_fd(fd, empty);
    acl_free(empty);
    if (result || fchmod(fd, directory ? 0700 : 0600)) return IOFail(error);
    return YES;
}
// Encrypt-then-MAC: independent random 256-bit AES and HMAC keys. The tag
// authenticates the version, random IV and ciphertext before CBC decryption.
static NSData *Seal(NSData *plain, NSData *key, NSError **error) {
    unsigned char iv[kCCBlockSizeAES128], tag[CC_SHA256_DIGEST_LENGTH];
    if (!KeychainStatus(SecRandomCopyBytes(kSecRandomDefault, sizeof(iv), iv), error)) return nil;
    NSMutableData *cipher = [NSMutableData dataWithLength:plain.length + kCCBlockSizeAES128];
    size_t count = 0;
    if (CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, kCCKeySizeAES256,
                iv, plain.bytes, plain.length, cipher.mutableBytes, cipher.length, &count)) {
        Fail(error, @"The login vault could not be encrypted.");
        return nil;
    }
    cipher.length = count;
    NSMutableData *sealed = [NSMutableData dataWithBytes:Header length:sizeof(Header)];
    [sealed appendBytes:iv length:sizeof(iv)];
    [sealed appendData:cipher];
    CCHmac(kCCHmacAlgSHA256, (const unsigned char *)key.bytes + 32, 32,
           sealed.bytes, sealed.length, tag);
    [sealed appendBytes:tag length:sizeof(tag)];
    return sealed;
}
static NSData *Unseal(NSData *sealed, NSData *key, NSError **error) {
    const NSUInteger prefix = sizeof(Header) + kCCBlockSizeAES128, tagSize = CC_SHA256_DIGEST_LENGTH;
    const unsigned char *bytes = sealed.bytes;
    if (sealed.length < prefix + kCCBlockSizeAES128 + tagSize ||
        memcmp(bytes, Header, sizeof(Header)) || (sealed.length - prefix - tagSize) % 16) {
        Fail(error, @"The vault is damaged or uses an unsupported format. It was preserved.");
        return nil;
    }
    unsigned char tag[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, (const unsigned char *)key.bytes + 32, 32,
           bytes, sealed.length - tagSize, tag);
    volatile unsigned char difference = 0;
    for (NSUInteger i = 0; i < tagSize; i++) difference |= tag[i] ^ bytes[sealed.length - tagSize + i];
    if (difference) {
        Fail(error, @"The vault could not be authenticated. Its contents and key were preserved.");
        return nil;
    }
    NSMutableData *plain = [NSMutableData dataWithLength:sealed.length];
    size_t count = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, kCCKeySizeAES256,
                bytes + sizeof(Header), bytes + prefix, sealed.length - prefix - tagSize,
                plain.mutableBytes, plain.length, &count)) {
        Fail(error, @"The vault could not be decrypted. It was preserved.");
        return nil;
    }
    plain.length = count;
    return plain;
}
static BOOL ValidRecords(id records) {
    if (![records isKindOfClass:NSArray.class]) return NO;
    NSMutableSet *identities = [NSMutableSet new];
    for (id row in records) {
        if (![row isKindOfClass:NSDictionary.class] ||
            ![row[@"origin"] isKindOfClass:NSString.class] ||
            ![row[@"username"] isKindOfClass:NSString.class] ||
            ![row[@"password"] isKindOfClass:NSString.class] ||
            ![LTLoginOrigin(row[@"origin"]) isEqual:row[@"origin"]] ||
            [row[@"username"] length] > 1024 || ![row[@"password"] length] ||
            [row[@"password"] length] > 16384) return NO;
        NSArray *identity = @[row[@"origin"], row[@"username"]];
        if ([identities containsObject:identity]) return NO;
        [identities addObject:identity];
    }
    return YES;
}
@implementation LTLoginVault {
    NSString *_profilePath;
    NSString *_keyService;
}
- (instancetype)initWithProfilePath:(NSString *)path keyService:(NSString *)service {
    if ((self = [super init])) { _profilePath = [path copy]; _keyService = [service copy]; }
    return self;
}
- (NSData *)keyCreatingIfNeeded:(BOOL)create error:(NSError **)error {
    NSMutableDictionary *query = [@{(id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: _keyService, (id)kSecAttrAccount: @"vault-key-v1"} mutableCopy];
    NSMutableDictionary *read = [query mutableCopy];
    read[(id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSData *key = CFBridgingRelease(result);
    if (status == errSecItemNotFound && create) {
        NSMutableData *random = [NSMutableData dataWithLength:64];
        if (!KeychainStatus(SecRandomCopyBytes(kSecRandomDefault, random.length, random.mutableBytes), error)) return nil;
        query[(id)kSecValueData] = random;
        query[(id)kSecAttrLabel] = @"Lite — encrypted login vault key";
        // Use the login Keychain's app ACL. Never store the key next to the vault,
        // permit all applications, or synchronize it to iCloud.
        query[(id)kSecAttrSynchronizable] = @NO;
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        if (status == errSecDuplicateItem) return [self keyCreatingIfNeeded:NO error:error];
        key = random;
    }
    if (status == errSecItemNotFound) {
        Fail(error, @"The vault key is missing from Keychain. Restore the original key; the vault was preserved.");
        return nil;
    }
    if (!KeychainStatus(status, error)) return nil;
    if (key.length != 64) { Fail(error, @"The vault key is invalid. It was not replaced."); return nil; }
    return key;
}
- (BOOL)writeRecords:(NSArray *)records directory:(int)directory key:(NSData *)key error:(NSError **)error {
    if (!ValidRecords(records)) return Fail(error, @"Invalid login records. The vault was preserved.");
    NSData *plain = [NSJSONSerialization dataWithJSONObject:records options:0 error:error];
    if (!plain) return NO;
    if (plain.length > MaxSize - 80) return Fail(error, @"The login vault has reached its size limit.");
    NSData *sealed = Seal(plain, key, error);
    if (!sealed) return NO;
    NSString *temporary = [@".vault-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(directory, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return IOFail(error);
    BOOL ok = Protect(fd, NO, error);
    NSUInteger offset = 0;
    while (ok && offset < sealed.length) {
        ssize_t count = write(fd, (const char *)sealed.bytes + offset, sealed.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = IOFail(error); break; }
        offset += count;
    }
    if (ok && fsync(fd)) ok = IOFail(error);
    if (close(fd) && ok) ok = IOFail(error);
    if (ok && renameat(directory, temporary.UTF8String, directory, "Logins.vault")) ok = IOFail(error);
    if (ok && fsync(directory)) ok = IOFail(error);
    unlinkat(directory, temporary.UTF8String, 0);
    return ok;
}
- (BOOL)accessDirectory:(int)directory action:(BOOL (^)(NSMutableArray *, BOOL *, NSError **))action
                  error:(NSError **)error {
    int fd = openat(directory, "Logins.vault", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    BOOL exists = fd >= 0;
    if (!exists && errno != ENOENT) return IOFail(error);
    NSMutableArray *records = [NSMutableArray new];
    NSData *key = nil;
    if (exists) {
        struct stat st;
        BOOL ok = Protect(fd, NO, error);
        if (ok && fstat(fd, &st)) ok = IOFail(error);
        if (ok && (st.st_size <= 0 || st.st_size > MaxSize))
            ok = Fail(error, @"The vault has an invalid size. It was preserved.");
        NSMutableData *sealed = ok ? [NSMutableData dataWithLength:(NSUInteger)st.st_size] : nil;
        NSUInteger offset = 0;
        while (ok && offset < sealed.length) {
            ssize_t count = read(fd, (char *)sealed.mutableBytes + offset, sealed.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { ok = Fail(error, @"The vault could not be read completely. It was preserved."); break; }
            offset += count;
        }
        close(fd);
        if (!ok) return NO;
        key = [self keyCreatingIfNeeded:NO error:error];
        if (!key) return NO;
        NSData *plain = Unseal(sealed, key, error);
        if (!plain) return NO;
        id decoded = [NSJSONSerialization JSONObjectWithData:plain options:0 error:nil];
        if (!ValidRecords(decoded)) return Fail(error, @"The vault contains invalid login records. It was preserved.");
        [records addObjectsFromArray:decoded];
    }
    BOOL changed = NO;
    if (!action(records, &changed, error)) return NO;
    if (!changed) return YES;
    if (!key) key = [self keyCreatingIfNeeded:YES error:error];
    return key && [self writeRecords:records directory:directory key:key error:error];
}
- (BOOL)withRecords:(BOOL (^)(NSMutableArray<NSDictionary *> *, BOOL *, NSError **))action
        afterCommit:(BOOL (^)(NSError **))cleanup error:(NSError **)error {
    if (error) *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:_profilePath withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    int profile = open(_profilePath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (profile < 0) return IOFail(error);
    struct stat st;
    if (fstat(profile, &st) || st.st_uid != getuid()) {
        close(profile);
        return Fail(error, @"The profile directory must be owned by your macOS account.");
    }
    if (mkdirat(profile, "Credentials", 0700) && errno != EEXIST) {
        IOFail(error); close(profile); return NO;
    }
    int directory = openat(profile, "Credentials", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(profile);
    if (directory < 0) return IOFail(error);
    BOOL ok = Protect(directory, YES, error);
    if (ok && flock(directory, LOCK_EX)) ok = IOFail(error);
    if (ok) ok = [self accessDirectory:directory action:action error:error];
    if (ok && cleanup) ok = cleanup(error);
    flock(directory, LOCK_UN);
    close(directory);
    return ok;
}
@end
