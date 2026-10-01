#import "../model/LTStore.h"
#import <sqlite3.h>
#include <unistd.h>
#include <sys/stat.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

// Test-only VFS faults exercise SQLite's real write/rollback paths. Production has no fault switches.
static sqlite3_vfs *Underlying;
static int WriteFault, SyncFault;
typedef struct { sqlite3_file file; sqlite3_file *inner; } FaultFile;
#define INNER(f) (((FaultFile *)(f))->inner)
static int Close(sqlite3_file *f) { return INNER(f)->pMethods->xClose(INNER(f)); }
static int Read(sqlite3_file *f, void *p, int n, sqlite3_int64 o) { return INNER(f)->pMethods->xRead(INNER(f),p,n,o); }
static int Write(sqlite3_file *f, const void *p, int n, sqlite3_int64 o) { if (WriteFault) { int fault = WriteFault; WriteFault = 0; return fault; } return INNER(f)->pMethods->xWrite(INNER(f),p,n,o); }
static int Truncate(sqlite3_file *f, sqlite3_int64 n) { return INNER(f)->pMethods->xTruncate(INNER(f),n); }
static int Sync(sqlite3_file *f, int n) { if (SyncFault) { int fault = SyncFault; SyncFault = 0; return fault; } return INNER(f)->pMethods->xSync(INNER(f),n); }
static int FileSize(sqlite3_file *f, sqlite3_int64 *n) { return INNER(f)->pMethods->xFileSize(INNER(f),n); }
static int Lock(sqlite3_file *f, int n) { return INNER(f)->pMethods->xLock(INNER(f),n); }
static int Unlock(sqlite3_file *f, int n) { return INNER(f)->pMethods->xUnlock(INNER(f),n); }
static int Reserved(sqlite3_file *f, int *n) { return INNER(f)->pMethods->xCheckReservedLock(INNER(f),n); }
static int Control(sqlite3_file *f, int n, void *p) { return INNER(f)->pMethods->xFileControl(INNER(f),n,p); }
static int Sector(sqlite3_file *f) { return INNER(f)->pMethods->xSectorSize(INNER(f)); }
static int Device(sqlite3_file *f) { return INNER(f)->pMethods->xDeviceCharacteristics(INNER(f)); }
static int Map(sqlite3_file *f,int p,int n,int e,void volatile **v) { return INNER(f)->pMethods->xShmMap(INNER(f),p,n,e,v); }
static int ShmLock(sqlite3_file *f,int o,int n,int flags) { return INNER(f)->pMethods->xShmLock(INNER(f),o,n,flags); }
static void Barrier(sqlite3_file *f) { INNER(f)->pMethods->xShmBarrier(INNER(f)); }
static int Unmap(sqlite3_file *f,int n) { return INNER(f)->pMethods->xShmUnmap(INNER(f),n); }
static int Fetch(sqlite3_file *f,sqlite3_int64 o,int n,void **p) { if (INNER(f)->pMethods->iVersion < 3) { *p=NULL; return SQLITE_OK; } return INNER(f)->pMethods->xFetch(INNER(f),o,n,p); }
static int Unfetch(sqlite3_file *f,sqlite3_int64 o,void *p) { return INNER(f)->pMethods->iVersion < 3 ? SQLITE_OK : INNER(f)->pMethods->xUnfetch(INNER(f),o,p); }
static const sqlite3_io_methods FaultMethods = {3,Close,Read,Write,Truncate,Sync,FileSize,Lock,Unlock,Reserved,Control,Sector,Device,Map,ShmLock,Barrier,Unmap,Fetch,Unfetch};
static int Open(sqlite3_vfs *v,const char *name,sqlite3_file *file,int flags,int *out) {
    FaultFile *wrapper = (FaultFile *)file;
    wrapper->inner = (sqlite3_file *)((char *)file + sizeof(FaultFile));
    int rc = Underlying->xOpen(Underlying,name,wrapper->inner,flags,out);
    if (rc == SQLITE_OK) wrapper->file.pMethods = &FaultMethods;
    return rc;
}
static NSMutableDictionary *Fixture(void) {
    LTProfile *profile = LTProfile.fresh;
    LTNode *node = [profile addNode:@"pinned" title:@"Kept bookmark" url:@"https://example.invalid/" space:profile.activeSpaceID parent:@""];
    [profile.windows addObject:@{@"space":profile.activeSpaceID,@"active":node.identifier,@"secondary":@"",@"ratio":@0.5,@"vertical":@YES,@"sidebarCollapsed":@NO,@"sidebarWidth":@240,@"frame":@"{{10, 20}, {900, 700}}"}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile.JSON options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}
static BOOL Rejected(id json) {
    NSError *error = nil;
    @try { return ![LTProfile fromJSON:json error:&error] && error != nil; }
    @catch (NSException *exception) { fprintf(stderr,"EXCEPTION %s\n",exception.reason.UTF8String); return NO; }
}
static void SQL(NSString *path, NSString *sql) {
    sqlite3 *db=NULL;
    if (sqlite3_open(path.fileSystemRepresentation,&db) != SQLITE_OK || sqlite3_exec(db,sql.UTF8String,NULL,NULL,NULL) != SQLITE_OK) {
        fprintf(stderr,"SQL fixture failed: %s\n", sqlite3_errmsg(db)); exit(2);
    }
    sqlite3_close(db);
}
static void ReplaceJSON(NSString *path, id json) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    sqlite3 *db=NULL; sqlite3_open(path.fileSystemRepresentation,&db);
    sqlite3_stmt *stmt=NULL; sqlite3_prepare_v2(db,"UPDATE profile SET json=? WHERE id=1",-1,&stmt,NULL);
    sqlite3_bind_blob(stmt,1,data.bytes,(int)data.length,SQLITE_TRANSIENT);
    CHECK(sqlite3_step(stmt)==SQLITE_DONE,"write malformed fixture into actual SQLite profile");
    sqlite3_finalize(stmt); sqlite3_close(db);
}
static NSString *NewPath(NSString *root) { return [[root stringByAppendingPathComponent:LTUUID()] stringByAppendingPathComponent:@"Lite.sqlite"]; }
static LTStore *Seed(NSString *path) {
    NSError *error=nil;
    LTStore *store=[[LTStore alloc]initWithPath:path error:&error];
    if (![store commit:^(LTProfile *p){ [p addSpace:@"Known good"]; } error:&error]) { NSLog(@"seed: %@",error); exit(2); }
    [store recordVisit:@"https://example.invalid/kept" title:@"Known good history"];
    store=nil;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-120]} ofItemAtPath:[path stringByAppendingString:@".backup"] error:nil];
    return [[LTStore alloc]initWithPath:path error:&error];
}
int main(int argc,char **argv) { @autoreleasepool {
    if (argc == 3 && !strcmp(argv[1],"--interrupt")) {
        sqlite3 *db=NULL; sqlite3_open(argv[2],&db);
        sqlite3_exec(db,"PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE profile SET json=zeroblob(4194304);",NULL,NULL,NULL);
        sqlite3_db_cacheflush(db);
        _exit(0); // Deliberately omit commit/rollback/close, like abrupt process termination.
    }
    Underlying=sqlite3_vfs_find(NULL);
    sqlite3_vfs faults=*Underlying; faults.zName="LiteTestFaults"; faults.szOsFile=(int)(sizeof(FaultFile)+Underlying->szOsFile); faults.xOpen=Open;
    sqlite3_vfs_register(&faults,1);
    NSError *error=nil;
    CHECK([LTProfile fromJSON:Fixture() error:&error]!=nil,"complete persisted window and node fixture validates");
    for (id bad in @[[NSNull null],@42,@YES,@"wrong",@[],@{}]) {
        CHECK(Rejected(bad),"malformed profile root returns an error without exception");
        for (NSString *key in @[@"id",@"kind",@"space",@"parent",@"title",@"customTitle",@"url",@"pinnedURL",@"favicon",@"order",@"expanded",@"lastUsed"]) {
            BOOL text = ![@[@"order",@"expanded",@"lastUsed"] containsObject:key];
            if ((text && [bad isKindOfClass:NSString.class]) || (!text && [bad isKindOfClass:NSNumber.class])) continue;
            NSMutableDictionary *j=Fixture(); j[@"nodes"][0][key]=bad;
            CHECK(Rejected(j),"malformed node field rejected before Objective-C conversion");
        }
        for (NSString *key in @[@"id",@"name",@"selected"]) {
            if ([bad isKindOfClass:NSString.class]) continue;
            NSMutableDictionary *j=Fixture(); j[@"spaces"][0][key]=bad;
            CHECK(Rejected(j),"malformed Space field rejected");
        }
    }
    NSMutableDictionary *j=Fixture(); j[@"nodes"][0][@"order"]=[NSNull null];
    CHECK(Rejected(j),"regression: order:null is a controlled recovery error");
    for (id bad in @[[NSNull null],@1,@"window",@[]]) {
        j=Fixture(); j[@"windows"]=@[bad]; CHECK(Rejected(j),"regression: nondictionary window cannot reach startup window restore");
    }
    for (NSString *key in @[@"space",@"active",@"secondary",@"frame",@"vertical",@"ratio",@"sidebarCollapsed",@"sidebarWidth",@"sessions",@"deferPages"]) {
        j=Fixture(); j[@"windows"][0][key]=[NSNull null]; CHECK(Rejected(j),"every window field rejects null");
    }
    for (NSString *key in @[@"performance",@"search",@"externalMini",@"onboarded",@"shortcuts",@"contentBlocking",@"githubLiveFolders"]) {
        j=Fixture(); j[@"settings"][key]=[NSNull null]; CHECK(Rejected(j),"every settings field rejects null");
    }
    for (NSDictionary *settings in @[@{@"shortcuts":@{@"newTab:":@{@"key":@"t",@"modifiers":@"cmd"}}},@{@"contentBlocking":@{@"disabledSites":@[@1]}},@{@"contentBlocking":@{@"disabled":@"yes"}},@{@"githubLiveFolders":@{@"f":@[]}},@{@"githubLiveFolders":@{@"f":@{@"username":@"test",@"repository":@"",@"mode":@"authored",@"draft":@"all",@"items":@[]}}}]) {
        j=Fixture(); j[@"settings"]=settings; CHECK(Rejected(j),"nested settings types are validated");
    }
    j=Fixture(); j[@"windows"][0][@"sessions"]=@{@"tab":@{@"url":@"https://example.invalid/",@"scrollX":@0,@"scrollY":@42}};
    CHECK([LTProfile fromJSON:j error:&error]!=nil,"bounded scroll restoration metadata validates");
    j[@"windows"][0][@"sessions"]=@{@"tab":@{@"url":@"https://example.invalid/",@"scrollX":@0,@"scrollY":@1e8}};
    CHECK(Rejected(j),"unbounded session scroll metadata rejected");
    j=Fixture(); j[@"windows"][0][@"ratio"]=@(NAN); CHECK(Rejected(j),"nonfinite window number rejected");
    j=Fixture(); j[@"nodes"][0][@"order"]=@0.5; CHECK(Rejected(j),"fractional sidebar order rejected");
    j=Fixture(); j[@"version"]=@YES; CHECK(Rejected(j),"boolean is not a profile version");
    j=Fixture(); j[@"version"]=@2; CHECK(Rejected(j),"unsupported profile version rejected");
    j=Fixture(); [j removeObjectForKey:@"settings"]; [j removeObjectForKey:@"windows"]; [j[@"nodes"][0] removeObjectForKey:@"lastUsed"];
    CHECK([LTProfile fromJSON:j error:&error]!=nil,"legacy version-one optional fields migrate safely");

    NSString *root=[@"/private/tmp" stringByAppendingPathComponent:[@"lite-recovery-tests-" stringByAppendingString:LTUUID()]];
    NSString *path=NewPath(root);
    LTStore *store=Seed(path);
    CHECK(store!=nil && !store.backupError && [LTStore recoveryAvailableAtPath:path],"durable known-good backup created");
    CHECK([[NSFileManager.defaultManager attributesOfItemAtPath:[path stringByAppendingString:@".backup"] error:nil][NSFilePosixPermissions] integerValue]==0600,"backup is private to its owner");
    [store commit:^(LTProfile *p){ p.settings[@"contentBlocking"]=[@{@"disabledSites":[NSMutableArray arrayWithObject:@"kept.invalid"]} mutableCopy]; } error:&error];
    CHECK(![store commit:^(LTProfile *p){ [p.settings[@"contentBlocking"][@"disabledSites"] addObject:@"not-saved.invalid"]; [p.spaces removeAllObjects]; } error:&error] &&
        [store.profile.settings[@"contentBlocking"][@"disabledSites"] count]==1,"rejected nested transaction cannot mutate original settings");
    NSUInteger spaces=store.profile.spaces.count;
    WriteFault=SQLITE_FULL;
    CHECK(![store commit:^(LTProfile *p){ [p addSpace:@"Disk full rejected"]; } error:&error] && store.profile.spaces.count==spaces,"SQLite disk exhaustion rolls back and preserves in-memory state");
    WriteFault=0; store=nil; store=[[LTStore alloc]initWithPath:path error:&error];
    CHECK(store.profile.spaces.count==spaces,"disk exhaustion preserves durable profile after reopen");
    SyncFault=SQLITE_IOERR_FSYNC;
    CHECK(![store commit:^(LTProfile *p){ [p addSpace:@"Interrupted sync rejected"]; } error:&error] && store.profile.spaces.count==spaces,"failed SQLite synchronization reports failure without publishing new state");
    SyncFault=0; store=nil; store=[[LTStore alloc]initWithPath:path error:&error];
    CHECK(store.profile.spaces.count==spaces,"failed synchronization preserves durable profile after reopen");
    store=nil;
    NSTask *child=[NSTask new]; child.executableURL=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]];
    child.arguments=@[@"--interrupt",path]; CHECK([child launchAndReturnError:&error],"launch interrupted-write subprocess"); [child waitUntilExit];
    store=[[LTStore alloc]initWithPath:path error:&error];
    CHECK(store.profile.spaces.count==spaces,"abrupt process exit during spilled WAL transaction preserves previous commit");
    store=nil;
    j=Fixture(); j[@"nodes"][0][@"order"]=[NSNull null]; ReplaceJSON(path,j);
    NSData *damaged=[NSData dataWithContentsOfFile:path];
    CHECK(![[LTStore alloc]initWithPath:path error:&error] && [damaged isEqual:[NSData dataWithContentsOfFile:path]],"damaged persisted node returns error without replacing original bytes");
    NSString *preserved=nil;
    CHECK([LTStore recoverProfileAtPath:path preservedPath:&preserved error:&error],"explicit recovery restores a validated known-good backup");
    CHECK([damaged isEqual:[NSData dataWithContentsOfFile:[preserved stringByAppendingPathComponent:@"Lite.sqlite"]]],"recovery preserves damaged original byte-for-byte");
    store=[[LTStore alloc]initWithPath:path error:&error];
    CHECK(store.profile.spaces.count==2 && [store history:@"kept" limit:10].count==1,"recovery restores profile and history from complete SQLite backup");
    store=nil;
    // Emulate termination after originals are preserved and the recovery marker is durable.
    NSString *marker=[path stringByAppendingString:@".recovery-pending"];
    [preserved.lastPathComponent writeToFile:marker atomically:NO encoding:NSUTF8StringEncoding error:&error];
    CHECK(![[LTStore alloc]initWithPath:path error:&error],"interrupted recovery cannot silently start a fresh profile");
    CHECK([LTStore recoverProfileAtPath:path preservedPath:nil error:&error] && [[LTStore alloc]initWithPath:path error:&error]!=nil,"explicit retry completes interrupted recovery");
    [@"Torn marker bytes" writeToFile:[marker stringByAppendingString:@".tmp"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    CHECK([LTStore recoverProfileAtPath:path preservedPath:nil error:&error] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[marker stringByAppendingString:@".tmp"]],"interrupted atomic marker write is safely retried before database replacement");
    SQL(path,@"PRAGMA user_version=99");
    damaged=[NSData dataWithContentsOfFile:path];
    CHECK(![[LTStore alloc]initWithPath:path error:&error] && ![LTStore recoveryAvailableAtPath:path] &&
        ![LTStore recoverProfileAtPath:path preservedPath:nil error:&error] && [damaged isEqual:[NSData dataWithContentsOfFile:path]],"newer database schema fails closed without downgrade or byte changes");
    SQL(path,@"PRAGMA user_version=0");
    store=[[LTStore alloc]initWithPath:path error:&error]; CHECK(store.profile.spaces.count==2,"legacy SQLite schema migration preserves profile"); store=nil;
    j=Fixture(); j[@"version"]=@2; ReplaceJSON(path,j);
    CHECK(![[LTStore alloc]initWithPath:path error:&error] && ![LTStore recoveryAvailableAtPath:path],"newer JSON schema cannot be downgraded through backup restore");
    NSString *rotated=NewPath(root);
    store=Seed(rotated); store=nil;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-120]} ofItemAtPath:[rotated stringByAppendingString:@".backup"] error:nil];
    [@"Interrupted backup contents" writeToFile:[rotated stringByAppendingString:@".backup.pending"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    store=[[LTStore alloc]initWithPath:rotated error:&error];
    CHECK(store && !store.backupError && ![NSFileManager.defaultManager fileExistsAtPath:[rotated stringByAppendingString:@".backup.pending"]],"interrupted backup replacement is retried from the valid live database");
    store=nil;
    [@"Corrupt newest backup" writeToFile:[rotated stringByAppendingString:@".backup"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    SQL(rotated,@"UPDATE profile SET json='broken json'");
    CHECK([LTStore recoveryAvailableAtPath:rotated] && [LTStore recoverProfileAtPath:rotated preservedPath:nil error:&error],"corrupt newest backup falls back to prior validated generation");
    store=[[LTStore alloc]initWithPath:rotated error:&error];
    CHECK(store.profile.spaces.count==2,"fallback backup restores actual known-good organization"); store=nil;
    for (int recovery=0; recovery<2; recovery++) CHECK([LTStore recoverProfileAtPath:rotated preservedPath:nil error:&error],"explicit recoveries preserve additional damaged originals");
    CHECK(![LTStore recoverProfileAtPath:rotated preservedPath:nil error:&error] && [error.localizedDescription containsString:@"Three damaged"],"preserved-original cap refuses recovery without deleting any damaged archive");
    NSString *unsafe=NewPath(root);
    store=Seed(unsafe); store=nil;
    NSString *backup=[unsafe stringByAppendingString:@".backup"];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-120]} ofItemAtPath:backup error:nil];
    NSString *sentinel=[root stringByAppendingPathComponent:@"sentinel"];
    [@"Untouched" writeToFile:sentinel atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:[unsafe stringByAppendingString:@".backup.pending"] withDestinationPath:sentinel error:nil];
    store=[[LTStore alloc]initWithPath:unsafe error:&error];
    CHECK(store && store.backupError && [[NSString stringWithContentsOfFile:sentinel encoding:NSUTF8StringEncoding error:nil] isEqual:@"Untouched"],"unsafe pending backup fails visibly without following symlink");
    CHECK([LTStore recoveryAvailableAtPath:unsafe],"backup failure retains existing known-good recovery");
    store=nil;
    NSString *linked=[root stringByAppendingPathComponent:@"linked.sqlite"];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:linked withDestinationPath:unsafe error:nil];
    CHECK(![[LTStore alloc]initWithPath:linked error:&error],"profile database symlinks fail closed");
    NSString *historyPath=NewPath(root);
    store=Seed(historyPath);
    WriteFault=SQLITE_FULL;
    CHECK(![store clearHistorySince:0 error:&error] && [store history:@"kept" limit:10].count==1,"history deletion reports real SQLite failure without claiming completion");
    WriteFault=0;
    CHECK([store clearHistorySince:0 error:&error] && [store history:@"kept" limit:10].count==0,"all-time history deletion completes and refreshes bounded recovery backup");
    store=nil;
    CHECK([LTStore recoverProfileAtPath:historyPath preservedPath:nil error:&error],"history-free backup remains recoverable");
    store=[[LTStore alloc]initWithPath:historyPath error:&error];
    CHECK([store history:@"kept" limit:10].count==0,"restoring backup cannot resurrect deleted browsing history");
    [store recordVisit:@"https://example.invalid/one" title:@"Delete one"];
    [store recordVisit:@"https://example.invalid/two" title:@"Keep two"];
    CHECK([store deleteHistoryURL:@"https://example.invalid/one" error:&error] && [store history:@"" limit:10].count==1,"single-history-entry deletion preserves unrelated entries");
    store=nil;
    CHECK([LTStore recoverProfileAtPath:historyPath preservedPath:nil error:&error],"single-entry deletion creates usable updated backup");
    store=[[LTStore alloc]initWithPath:historyPath error:&error];
    CHECK([store history:@"one" limit:10].count==0 && [store history:@"two" limit:10].count==1,"updated recovery honors individual history deletion"); store=nil;
    NSString *privatePath=NewPath(root);
    LTStore *privateStore=[[LTStore alloc]initWithPath:nil error:&error];
    CHECK(privateStore.privateMode && !privateStore.backupError && ![NSFileManager.defaultManager fileExistsAtPath:privatePath],"private profile remains ephemeral without disk backups");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    sqlite3_vfs_unregister(&faults);
    printf("\n%d passed, %d failed\n",passed,failed);
    return failed ? 1 : 0;
}}
