#import "../model/LTLoginVault.h"
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

// Tests inject synthetic key material only in this test executable. Production
// LTLoginVault always obtains its key through Security.framework.
@interface TestVault : LTLoginVault
@property NSData *testKey;
@end
@implementation TestVault
- (NSData *)keyCreatingIfNeeded:(BOOL)create error:(NSError **)error {
    if (!_testKey && error) *error = [NSError errorWithDomain:@"SyntheticMissingKey" code:1 userInfo:nil];
    return _testKey;
}
@end
static int failures;
#define CHECK(c, name) do { if (!(c)) { fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); failures++; } \
    else printf("PASS %s\n", name); } while (0)
static TestVault *Vault(NSString *path, NSData *key) {
    TestVault *vault = [[TestVault alloc] initWithProfilePath:path keyService:@"synthetic-unused"];
    vault.testKey = key;
    return vault;
}
static NSDictionary *Record(NSString *username) {
    return @{@"origin": @"https://vault.lite.invalid", @"username": username, @"password": @"Synthetic-secret-密碼-🔒"};
}
static BOOL Add(TestVault *vault, NSString *username, NSError **error) {
    return [vault withRecords:^BOOL(NSMutableArray *rows, BOOL *changed, NSError **failure) {
        [rows addObject:Record(username)]; *changed = YES; return YES;
    } afterCommit:nil error:error];
}
static NSArray *Read(TestVault *vault, NSError **error) {
    __block NSArray *result;
    BOOL ok = [vault withRecords:^BOOL(NSMutableArray *rows, BOOL *changed, NSError **failure) {
        result = [rows copy]; return YES;
    } afterCommit:nil error:error];
    return ok ? result : nil;
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *path = [root stringByAppendingPathComponent:@"profile"];
        NSString *directory = [path stringByAppendingPathComponent:@"Credentials"];
        NSString *file = [directory stringByAppendingPathComponent:@"Logins.vault"];
        NSMutableData *key = [NSMutableData dataWithLength:64];
        arc4random_buf(key.mutableBytes, key.length);
        TestVault *vault = Vault(path, key);
        NSError *error = nil;
        CHECK(Read(vault, &error).count == 0 && !error, "new vault lists no records without creating a key");
        CHECK(Add(vault, @"first-account", &error), "encrypt and persist a synthetic account");
        NSData *original = [NSData dataWithContentsOfFile:file];
        CHECK(original.length > 0, "one encrypted vault file exists");
        for (NSString *secret in @[@"first-account", @"vault.lite.invalid", Record(@"")[@"password"]]) {
            NSData *bytes = [secret dataUsingEncoding:NSUTF8StringEncoding];
            CHECK([original rangeOfData:bytes options:0 range:NSMakeRange(0, original.length)].location == NSNotFound,
                  "site, username and password are absent from on-disk ciphertext");
        }
        struct stat st;
        CHECK(!stat(file.fileSystemRepresentation, &st) && (st.st_mode & 0777) == 0600, "vault permissions are 0600");
        CHECK(!stat(directory.fileSystemRepresentation, &st) && (st.st_mode & 0777) == 0700, "vault directory permissions are 0700");
        CHECK([Read(Vault(path, key), &error) isEqual:@[Record(@"first-account")]], "recreated store decrypts Unicode credentials");
        CHECK(Add(Vault(path, key), @"second-account", &error) && Read(vault, &error).count == 2,
              "multiple accounts share the same vault and independent stores reload updates");
        CHECK([NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil].count == 1,
              "committed vault leaves no extra credential files");
        original = [NSData dataWithContentsOfFile:file];
        CHECK([vault withRecords:^BOOL(NSMutableArray *rows, BOOL *changed, NSError **failure) {
            *changed = YES; return YES;
        } afterCommit:nil error:&error] && ![original isEqual:[NSData dataWithContentsOfFile:file]],
              "fresh random IV makes each encryption different");
        original = [NSData dataWithContentsOfFile:file];
        __block BOOL cleanupCalled = NO;
        CHECK(![vault withRecords:^BOOL(NSMutableArray *rows, BOOL *changed, NSError **failure) {
            [rows removeAllObjects]; *changed = YES; return NO;
        } afterCommit:^BOOL(NSError **failure) { cleanupCalled = YES; return YES; } error:&error] &&
            !cleanupCalled && [original isEqual:[NSData dataWithContentsOfFile:file]],
              "aborted transaction preserves file and migration source");
        for (NSNumber *position in @[@0, @8, @24, @(original.length - 1)]) {
            NSMutableData *damaged = [original mutableCopy];
            ((unsigned char *)damaged.mutableBytes)[position.unsignedIntegerValue] ^= 1;
            [damaged writeToFile:file atomically:NO];
            CHECK(!Read(vault, &error) && error && !Add(vault, @"no-overwrite", &error) &&
                  [damaged isEqual:[NSData dataWithContentsOfFile:file]],
                  "modified header, IV, ciphertext or tag is rejected without overwriting");
        }
        [[original subdataWithRange:NSMakeRange(0, 10)] writeToFile:file atomically:NO];
        CHECK(!Read(vault, &error), "truncated vault is rejected");
        [original writeToFile:file atomically:NO];
        CHECK(!Add(Vault(path, [NSMutableData dataWithLength:64]), @"wrong-key", &error) &&
              [original isEqual:[NSData dataWithContentsOfFile:file]], "wrong key cannot overwrite vault");
        CHECK(!Add(Vault(path, nil), @"missing-key", &error) &&
              [original isEqual:[NSData dataWithContentsOfFile:file]], "missing key cannot reset vault");
        CHECK(!Add(vault, @"first-account", &error) && [original isEqual:[NSData dataWithContentsOfFile:file]],
              "duplicate identities are rejected before commit");
        chmod(file.fileSystemRepresentation, 0644);
        chmod(directory.fileSystemRepresentation, 0755);
        CHECK(Read(vault, &error).count == 2 && !stat(file.fileSystemRepresentation, &st) &&
              (st.st_mode & 0777) == 0600 && !stat(directory.fileSystemRepresentation, &st) &&
              (st.st_mode & 0777) == 0700, "opening vault repairs overly broad mode bits");
        NSString *moved = [root stringByAppendingPathComponent:@"untouched"];
        [NSFileManager.defaultManager moveItemAtPath:file toPath:moved error:nil];
        symlink(moved.fileSystemRepresentation, file.fileSystemRepresentation);
        CHECK(!Read(vault, &error) && [original isEqual:[NSData dataWithContentsOfFile:moved]], "symlink vault is rejected");
        unlink(file.fileSystemRepresentation);
        link(moved.fileSystemRepresentation, file.fileSystemRepresentation);
        CHECK(!Read(vault, &error), "hard-linked vault is rejected");
        unlink(file.fileSystemRepresentation);
        [NSFileManager.defaultManager moveItemAtPath:moved toPath:file error:nil];
        NSString *elsewhere = [root stringByAppendingPathComponent:@"elsewhere"];
        [NSFileManager.defaultManager moveItemAtPath:directory toPath:elsewhere error:nil];
        symlink(elsewhere.fileSystemRepresentation, directory.fileSystemRepresentation);
        CHECK(!Add(vault, @"symlink-directory", &error), "symlink credential directory is rejected");
        unlink(directory.fileSystemRepresentation);
        [NSFileManager.defaultManager moveItemAtPath:elsewhere toPath:directory error:nil];
        dispatch_apply(12, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
            @autoreleasepool { Add(Vault(path, key), [NSString stringWithFormat:@"concurrent-%zu", i], nil); }
        });
        CHECK(Read(vault, &error).count == 14, "concurrent stores serialize updates without losing accounts");
        CHECK([vault withRecords:^BOOL(NSMutableArray *rows, BOOL *changed, NSError **failure) {
            [rows removeAllObjects]; *changed = YES; return YES;
        } afterCommit:^BOOL(NSError **failure) {
            cleanupCalled = YES;
            return YES;
        } error:&error] && cleanupCalled && Read(vault, &error).count == 0, "delete commits an authenticated empty vault");
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        printf("%d vault failures\n", failures);
    }
    return failures ? 1 : 0;
}
