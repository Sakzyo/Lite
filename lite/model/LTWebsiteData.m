#import "LTWebsiteData.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>

static BOOL SyncDirectory(NSString *path, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    BOOL ok = fd >= 0 && fsync(fd) == 0;
    int code = errno;
    if (fd >= 0) close(fd);
    if (!ok && error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    return ok;
}

BOOL LTRequestWebsiteDataClear(NSString *profilePath, NSError **error) {
    NSString *marker = [profilePath stringByAppendingPathComponent:@"ClearWebsiteData.pending"];
    NSString *staging = [marker stringByAppendingString:@".staging"];
    NSData *data = [@"Lite website data reset v1\n" dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(staging.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    BOOL ok = write(fd, data.bytes, data.length) == (ssize_t)data.length && fsync(fd) == 0;
    int code = errno;
    close(fd);
    if (!ok) {
        unlink(staging.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    if (renamex_np(staging.fileSystemRepresentation, marker.fileSystemRepresentation, RENAME_EXCL)) {
        int code = errno;
        unlink(staging.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    if (!SyncDirectory(profilePath, error)) {
        unlink(marker.fileSystemRepresentation);
        SyncDirectory(profilePath, nil);
        return NO;
    }
    return YES;
}

static BOOL NoActiveEngine(NSString *path, NSError **error) {
    NSString *lock = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:[path stringByAppendingPathComponent:@"SingletonLock"] error:nil];
    if (!lock.length) return YES;
    NSString *pidText = [lock componentsSeparatedByString:@"-"].lastObject;
    NSScanner *scanner = [NSScanner scannerWithString:pidText];
    int pid = 0;
    if (![scanner scanInt:&pid] || !scanner.isAtEnd || pid <= 0 || kill(pid, 0) == 0 || errno == EPERM) {
        if (error) *error = [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Another browser may still be using this Chromium profile. Close it before retrying the reset."}];
        return NO;
    }
    return YES;
}

BOOL LTPerformPendingWebsiteDataClear(NSString *profilePath, BOOL *cleared, NSError **error) {
    if (cleared) *cleared = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *marker = [profilePath stringByAppendingPathComponent:@"ClearWebsiteData.pending"];
    NSString *staging = [marker stringByAppendingString:@".staging"];
    struct stat info;
    if (lstat(staging.fileSystemRepresentation, &info) == 0) {
        if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 ||
            ![fm removeItemAtPath:staging error:error]) return NO;
    }
    if (lstat(marker.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return YES;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || info.st_size > 128) {
        if (error) *error = [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsafe website-data reset marker. No browser data was opened."}];
        return NO;
    }
    NSString *text = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:error];
    if (![text isEqual:@"Lite website data reset v1\n"]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The pending website-data reset marker is damaged. It was preserved and Chromium was not started."}];
        return NO;
    }
    NSString *source = [profilePath stringByAppendingPathComponent:@"Chromium"];
    NSString *pending = [profilePath stringByAppendingPathComponent:@"Chromium.pending-clear"];
    if (!NoActiveEngine(source, error) || !NoActiveEngine(pending, error)) return NO;
    for (NSString *path in @[source, pending]) {
        int status = lstat(path.fileSystemRepresentation, &info);
        if (status != 0 && errno != ENOENT) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
        if (status == 0 &&
            (!S_ISDIR(info.st_mode) || info.st_uid != getuid())) {
            if (error) *error = [NSError errorWithDomain:@"Lite" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsafe Chromium data directory. The reset was stopped."}];
            return NO;
        }
    }
    // Recover a interrupted deletion before moving the live tree. Never start CEF
    // against a partially cleared partition or remove Lite's vault/organization.
    if ([fm fileExistsAtPath:pending] && ![fm removeItemAtPath:pending error:error]) return NO;
    if ([fm fileExistsAtPath:source]) {
        if (![fm moveItemAtPath:source toPath:pending error:error] || !SyncDirectory(profilePath, error)) return NO;
        if (!NoActiveEngine(pending, error)) return NO;
        if (![fm removeItemAtPath:pending error:error]) return NO;
    }
    if (!SyncDirectory(profilePath, error) || ![fm removeItemAtPath:marker error:error] ||
        !SyncDirectory(profilePath, error)) return NO;
    if (cleared) *cleared = YES;
    return YES;
}
