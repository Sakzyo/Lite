#import "../model/LTStore.h"
#import <sqlite3.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
static int passed, failed;
#define CHECK(condition, name) do { if (condition) { passed++; printf("PASS %s\n", name); } else { failed++; fprintf(stderr, "FAIL %s (line %d)\n", name, __LINE__); } } while (0)

// Test-only VFS faults exercise SQLite's real write/rollback paths. Production has no fault switches.
static sqlite3_vfs *Underlying;
static int WriteFault, SyncFault;
// Parks the next sync, with the transaction open, until the test lets it go.
static dispatch_semaphore_t SyncGate, SyncEntered;
typedef struct { sqlite3_file file; sqlite3_file *inner; } FaultFile;
#define INNER(f) (((FaultFile *)(f))->inner)
static int Close(sqlite3_file *f) { return INNER(f)->pMethods->xClose(INNER(f)); }
static int Read(sqlite3_file *f, void *p, int n, sqlite3_int64 o) { return INNER(f)->pMethods->xRead(INNER(f),p,n,o); }
static int Write(sqlite3_file *f, const void *p, int n, sqlite3_int64 o) { if (WriteFault) { int fault = WriteFault; WriteFault = 0; return fault; } return INNER(f)->pMethods->xWrite(INNER(f),p,n,o); }
static int Truncate(sqlite3_file *f, sqlite3_int64 n) { return INNER(f)->pMethods->xTruncate(INNER(f),n); }
static int Sync(sqlite3_file *f, int n) {
    if (SyncGate) { dispatch_semaphore_t gate = SyncGate; SyncGate = nil; dispatch_semaphore_signal(SyncEntered); dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); }
    if (SyncFault) { int fault = SyncFault; SyncFault = 0; return fault; }
    return INNER(f)->pMethods->xSync(INNER(f),n);
}
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
    [store waitForWrites];
    store=nil;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-120]} ofItemAtPath:[path stringByAppendingString:@".backup"] error:nil];
    return [[LTStore alloc]initWithPath:path error:&error];
}
// The writer's tests read the file through their own connection, so they cannot be fooled by the store's memory.
static NSArray<NSString *> *SavedSpaces(NSString *path) {
    sqlite3 *db=NULL; sqlite3_stmt *stmt=NULL; NSMutableArray *names=[NSMutableArray new];
    sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL);
    sqlite3_prepare_v2(db,"SELECT json FROM profile WHERE id=1",-1,&stmt,NULL);
    if (sqlite3_step(stmt)==SQLITE_ROW) {
        NSDictionary *json=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:sqlite3_column_blob(stmt,0) length:sqlite3_column_bytes(stmt,0)] options:0 error:nil];
        for (NSDictionary *space in json[@"spaces"]) if ([space[@"name"] hasPrefix:@"w"]) [names addObject:space[@"name"]];
    }
    sqlite3_finalize(stmt); sqlite3_close(db);
    return names;
}
static NSArray<NSString *> *SavedVisits(NSString *path) {
    sqlite3 *db=NULL; sqlite3_stmt *stmt=NULL; NSMutableArray *urls=[NSMutableArray new];
    sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL);
    sqlite3_prepare_v2(db,"SELECT url FROM history ORDER BY visited,rowid",-1,&stmt,NULL);
    while (sqlite3_step(stmt)==SQLITE_ROW) [urls addObject:@((const char *)sqlite3_column_text(stmt,0))];
    sqlite3_finalize(stmt); sqlite3_close(db);
    return urls;
}
static NSArray<NSString *> *MemorySpaces(LTStore *store) {
    NSMutableArray *names=[NSMutableArray new];
    for (LTSpace *space in store.profile.spaces) if ([space.name hasPrefix:@"w"]) [names addObject:space.name];
    return names;
}
static BOOL Spin(BOOL (^done)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while (!done() && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    return done();
}
static BOOL Integrity(NSString *path) {
    sqlite3 *db=NULL; sqlite3_stmt *stmt=NULL;
    sqlite3_open_v2(path.fileSystemRepresentation,&db,SQLITE_OPEN_READONLY,NULL);
    BOOL ok=sqlite3_prepare_v2(db,"PRAGMA quick_check",-1,&stmt,NULL)==SQLITE_OK && sqlite3_step(stmt)==SQLITE_ROW && !strcmp((const char *)sqlite3_column_text(stmt,0),"ok");
    sqlite3_finalize(stmt); sqlite3_close(db);
    return ok;
}
// Records where the last release of a block's captured object happens.
@interface LTReleaseProbe : NSObject
@property (nonatomic, copy) void (^onRelease)(BOOL mainThread);
@end
@implementation LTReleaseProbe
- (void)dealloc { if (_onRelease) _onRelease(NSThread.isMainThread); }
@end
static const int CrashWrites = 200;
static int RunWriterCrashChild(const char *path, int killAfterMs) {
    NSError *error=nil;
    LTStore *store=[[LTStore alloc]initWithPath:@(path) error:&error];
    if (!store) return 3;
    for (int i=0;i<CrashWrites;i++) {
        NSString *name=[NSString stringWithFormat:@"w%03d",i];
        [store commit:^(LTProfile *p){
            // A timer started by the first write lands anywhere, including inside a commit. The hard
            // stop further on guarantees that the process dies with writes still queued behind it.
            if (i==0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,killAfterMs*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{ kill(getpid(),SIGKILL); });
            if (i==CrashWrites-50) kill(getpid(),SIGKILL);
            [p addSpace:name];
        } completion:nil];
        [store recordVisit:[NSString stringWithFormat:@"https://example.invalid/%03d",i] title:name];
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:30]];
    return 4;
}
static void WriterTests(NSString *root, const char *program) {
    NSError *error=nil;
    __block int changes=0, failures=0;
    __block id quiet=nil;
    id changed=[NSNotificationCenter.defaultCenter addObserverForName:LTStoreChanged object:nil queue:nil usingBlock:^(NSNotification *n) { changes++; quiet=n.userInfo[LTStoreChangeQuietObserverKey]; }];
    id failedWrites=[NSNotificationCenter.defaultCenter addObserverForName:LTStoreWriteFailed object:nil queue:nil usingBlock:^(NSNotification *n) { failures++; }];

    // Ordering.
    NSString *path=NewPath(root);
    LTStore *store=[[LTStore alloc]initWithPath:path error:&error];
    NSMutableArray *expected=[NSMutableArray new], *delivered=[NSMutableArray new];
    __block BOOL ranOnMain=NO, sawOwnWrite=YES;
    for (int i=0;i<50;i++) {
        NSString *name=[NSString stringWithFormat:@"w%02d",i];
        [expected addObject:name];
        [store commit:^(LTProfile *p){ ranOnMain=ranOnMain||NSThread.isMainThread; [p addSpace:name]; } completion:^(NSError *e) {
            sawOwnWrite=sawOwnWrite && !e && NSThread.isMainThread && [MemorySpaces(store) containsObject:name];
            [delivered addObject:name];
        }];
        [store recordVisit:[NSString stringWithFormat:@"https://example.invalid/%02d",i] title:name];
    }
    CHECK(Spin(^{ return (BOOL)(delivered.count==50); }),"every queued save completes");
    CHECK(!ranOnMain,"a queued change runs on the writer, not the main thread");
    CHECK([delivered isEqual:expected],"completions arrive in submission order");
    CHECK(sawOwnWrite,"a completion runs on the main thread with its write already in the model");
    CHECK([SavedSpaces(path) isEqual:expected] && [MemorySpaces(store) isEqual:expected],"queued saves reach disk and the model in submission order");
    [store waitForWrites];
    CHECK(SavedVisits(path).count==50 && [SavedVisits(path).firstObject hasSuffix:@"/00"] && [SavedVisits(path).lastObject hasSuffix:@"/49"],"queued visits are recorded in order with saves");

    [store clearHistorySince:0 error:nil];
    [store recordVisit:@"https://example.invalid/before" title:@"Before"];
    __block BOOL cleared=NO;
    [store clearHistorySince:0 completion:^(NSError *e){ cleared=!e; }];
    [store recordVisit:@"https://example.invalid/after" title:@"After"];
    CHECK(Spin(^{ return cleared; }),"queued history deletion completes");
    [store waitForWrites];
    CHECK([SavedVisits(path) isEqual:@[@"https://example.invalid/after"]],"history deletion removes earlier queued visits and keeps later ones");
    __block BOOL deleted=NO;
    [store deleteHistoryURL:@"https://example.invalid/after" completion:^(NSError *e){ deleted=!e; }];
    CHECK(Spin(^{ return deleted; }) && [store history:@"" limit:10].count==0,"queued single history deletion completes");

    // The main thread never waits for a write, even one holding the database inside its fsync.
    store=[[LTStore alloc]initWithPath:NewPath(root) error:&error];
    [store recordVisit:@"https://example.invalid/kept" title:@"Kept"];
    [store waitForWrites];
    NSUInteger before=store.profile.spaces.count;
    int changesBefore=changes;
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    SyncEntered=dispatch_semaphore_create(0);
    SyncGate=gate;
    __block BOOL finished=NO;
    [store commit:^(LTProfile *p){ [p addSpace:@"w-held"]; } completion:^(NSError *e){ finished=YES; }];
    CHECK(dispatch_semaphore_wait(SyncEntered,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0,"fixture holds a real commit inside its fsync");
    CHECK(!finished && store.profile.spaces.count==before && changes==changesBefore,"the model does not change before the commit succeeds");
    CHECK([store history:@"kept" limit:10].count==1,"history reads do not wait for a commit in progress");
    [store commit:^(LTProfile *p){ [p addSpace:@"w-after"]; } completion:nil];
    [store recordVisit:@"https://example.invalid/also" title:@"Also"];
    CHECK(store.profile.spaces.count==before,"queueing more work returns while the writer is busy");
    dispatch_semaphore_signal(gate);
    CHECK(Spin(^{ return finished; }) && store.profile.spaces.count>=before+1,"the model changes after the held commit succeeds");
    [store waitForWrites];
    CHECK([MemorySpaces(store) isEqual:(@[@"w-held",@"w-after"])],"writes queued behind a held commit still run in order");

    // Mixing queued saves with a save that waits, and with a completion that waits.
    store=[[LTStore alloc]initWithPath:NewPath(root) error:&error];
    NSMutableArray *order=[NSMutableArray new];
    [store commit:^(LTProfile *p){ [p addSpace:@"w0"]; } completion:^(NSError *e){ [order addObject:@"w0"]; }];
    [store commit:^(LTProfile *p){ [p addSpace:@"w1"]; } completion:^(NSError *e){
        [order addObject:@"w1"];
        NSError *nested=nil;
        [store commit:^(LTProfile *p){ [p addSpace:@"w3"]; } error:&nested];
        [order addObject:@"w3"];
    }];
    [store commit:^(LTProfile *p){ [p addSpace:@"w2"]; } completion:^(NSError *e){ [order addObject:@"w2"]; }];
    CHECK([store commit:^(LTProfile *p){ [p addSpace:@"w-sync"]; } error:&error] && order.count==4,"a save that waits delivers every earlier result before it returns");
    CHECK([order isEqual:(@[@"w0",@"w1",@"w2",@"w3"])],"a completion that saves and waits does not reorder delivery");
    NSArray *settled=MemorySpaces(store);
    CHECK([settled.lastObject isEqual:@"w3"] && settled.count==5,"a save that waits is in the model when it returns");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    CHECK([MemorySpaces(store) isEqual:settled],"late main-queue deliveries cannot move the model backwards");

    // One redraw for a burst, and a quiet save stays quiet for the window that made it.
    store=[[LTStore alloc]initWithPath:NewPath(root) error:&error];
    id window=[NSObject new];
    changesBefore=changes;
    for (int i=0;i<5;i++) [store commit:^(LTProfile *p){ [p addSpace:@"w"]; } quietFor:window completion:nil];
    [store waitForWrites];
    CHECK(changes==changesBefore+1 && quiet==window,"writes that finish together post one quiet LTStoreChanged");
    [store commit:^(LTProfile *p){ [p addSpace:@"w"]; } quietFor:window completion:nil];
    [store commit:^(LTProfile *p){ [p addSpace:@"w"]; } completion:nil];
    [store waitForWrites];
    CHECK(quiet==nil,"a loud write in the same batch redraws everyone");

    // Failure: the failed write is dropped alone, whatever the UI has done since.
    path=NewPath(root);
    store=[[LTStore alloc]initWithPath:path error:&error];
    __block NSError *second=nil, *third=(NSError *)@"unset";
    int failuresBefore=failures; changesBefore=changes;
    [store commit:^(LTProfile *p){ [p addSpace:@"w0"]; } completion:nil];
    [store commit:^(LTProfile *p){ WriteFault=SQLITE_FULL; [p addSpace:@"w1"]; } completion:^(NSError *e){ second=e; }];
    [store commit:^(LTProfile *p){ [p addSpace:@"w2"]; } completion:^(NSError *e){ third=e; }];
    [store waitForWrites];
    CHECK(second!=nil && third==nil,"only the write that hit a disk fault reports failure");
    CHECK(failures==failuresBefore,"a completion that receives the error owns it");
    CHECK(changes>changesBefore,"a failed write still redraws windows from the committed model");
    CHECK([MemorySpaces(store) isEqual:(@[@"w0",@"w2"])] && [SavedSpaces(path) isEqual:MemorySpaces(store)],"later writes run on the last commit; disk and model agree without the failed write");
    [store commit:^(LTProfile *p){ SyncFault=SQLITE_IOERR_FSYNC; [p addSpace:@"w3"]; } completion:nil];
    [store waitForWrites];
    CHECK(failures==failuresBefore+1,"a failed write without a completion posts LTStoreWriteFailed");
    CHECK([MemorySpaces(store) isEqual:(@[@"w0",@"w2"])] && [SavedSpaces(path) isEqual:MemorySpaces(store)],"a failed fsync rolls back and leaves the model alone");
    __block NSString *addedID=nil;
    __block NSError *dependent=nil, *invalid=nil, *raised=nil, *after=(NSError *)@"unset";
    NSString *spaceID=store.profile.activeSpaceID;
    [store commit:^(LTProfile *p){ WriteFault=SQLITE_FULL; addedID=[p addNode:@"pinned" title:@"Lost" url:@"https://example.invalid/" space:spaceID parent:@""].identifier; } completion:^(NSError *e){}];
    [store commit:^(LTProfile *p){ [p space:spaceID].selectedID=addedID; } completion:^(NSError *e){ dependent=e; }];
    [store commit:^(LTProfile *p){ p.activeSpaceID=@"missing"; } completion:^(NSError *e){ invalid=e; }];
    [store commit:^(LTProfile *p){ [NSException raise:@"LiteTestException" format:@"from a change"]; } completion:^(NSError *e){ raised=e; }];
    [store commit:^(LTProfile *p){ [p addSpace:@"w4"]; } completion:^(NSError *e){ after=e; }];
    [store waitForWrites];
    CHECK(dependent!=nil,"a write that depends on a dropped write fails validation by itself");
    CHECK(invalid!=nil,"a queued write that fails validation is dropped before SQLite");
    CHECK(raised!=nil,"a change that raises is dropped and does not stop the writer");
    CHECK(after==nil && [MemorySpaces(store) isEqual:(@[@"w0",@"w2",@"w4"])] && [SavedSpaces(path) isEqual:MemorySpaces(store)],"the writer keeps saving after failures");
    WriteFault=0; SyncFault=0;
    [store commit:^(LTProfile *p){ WriteFault=SQLITE_FULL; } completion:^(NSError *e){}];
    [store recordVisit:@"https://example.invalid/lost" title:@"Lost"];
    [store recordVisit:@"https://example.invalid/kept" title:@"Kept"];
    [store waitForWrites];
    WriteFault=0;
    CHECK([store history:@"kept" limit:10].count==1,"a visit that fails does not stop later visits");

    // Whatever a change captured is released on the main thread, never on the writer.
    __block BOOL releasedOnMain=NO, released=NO;
    @autoreleasepool {
        LTReleaseProbe *probe=[LTReleaseProbe new];
        probe.onRelease=^(BOOL mainThread){ releasedOnMain=mainThread; released=YES; };
        [store commit:^(LTProfile *p){ (void)probe; [p addSpace:@"w5"]; } completion:nil];
        probe=nil;
    }
    Spin(^{ return released; });
    CHECK(released && releasedOnMain,"objects captured by a change are released on the main thread");

    // Shutdown.
    path=NewPath(root);
    @autoreleasepool {
        LTStore *released=[[LTStore alloc]initWithPath:path error:&error];
        for (int i=0;i<10;i++) { NSString *name=[NSString stringWithFormat:@"w%d",i]; [released commit:^(LTProfile *p){ [p addSpace:name]; } completion:nil]; }
        [released recordVisit:@"https://example.invalid/kept" title:@"Kept"];
    }
    // The released store closes its database on the writer once the last block ends, so read until both settle.
    CHECK(Spin(^{ return (BOOL)(SavedVisits(path).count==1 && SavedSpaces(path).count==10); }),"releasing the store does not lose queued writes");
    path=NewPath(root);
    store=[[LTStore alloc]initWithPath:path error:&error];
    expected=[NSMutableArray new];
    __block int closedCompletions=0;
    for (int i=0;i<40;i++) {
        NSString *name=[NSString stringWithFormat:@"w%02d",i];
        [expected addObject:name];
        [store commit:^(LTProfile *p){ [p addSpace:name]; } completion:^(NSError *e){ closedCompletions++; }];
    }
    [store recordVisit:@"https://example.invalid/last" title:@"Last"];
    [store close];
    // macOS SQLite keeps the WAL file after a clean close, so an empty one is what proves the checkpoint.
    CHECK([[NSFileManager.defaultManager attributesOfItemAtPath:[path stringByAppendingString:@"-wal"] error:nil] fileSize]==0,"close checkpoints everything out of the WAL");
    CHECK([SavedSpaces(path) isEqual:expected] && SavedVisits(path).count==1,"close finishes every queued write before it returns");
    CHECK(closedCompletions==0,"close delivers no completions into a closing app");
    CHECK(Integrity(path),"the database is intact after close");
    __block NSError *refused=nil;
    [store commit:^(LTProfile *p){ [p addSpace:@"w-late"]; } completion:^(NSError *e){ refused=e; }];
    CHECK(Spin(^{ return (BOOL)(refused!=nil); }),"a queued write after close reports that it was refused");
    CHECK(![store commit:^(LTProfile *p){ [p addSpace:@"w-late"]; } error:&error] && ![store clearHistorySince:0 error:&error],"a waiting write after close fails instead of hanging");
    [store recordVisit:@"https://example.invalid/late" title:@"Late"];
    [store waitForWrites];
    [store close];
    CHECK([store history:@"" limit:10].count==0 && [SavedSpaces(path) isEqual:expected] && SavedVisits(path).count==1,"nothing reaches the database after close");
    LTStore *reopened=[[LTStore alloc]initWithPath:path error:&error];
    CHECK(reopened.profile.spaces.count==41 && [reopened history:@"last" limit:10].count==1,"a closed profile reopens with its queued writes");
    reopened=nil;

    // A private store uses the same writer with an in-memory database.
    store=[[LTStore alloc]initWithPath:nil error:&error];
    __block BOOL privateSaved=NO;
    [store commit:^(LTProfile *p){ [p addSpace:@"w0"]; } completion:^(NSError *e){ privateSaved=!e; }];
    [store recordVisit:@"https://private.example/" title:@"Private"];
    CHECK(Spin(^{ return privateSaved; }) && MemorySpaces(store).count==1 && [store history:@"" limit:10].count==0,"private saves are queued and private visits stay unrecorded");

    // Crash: SIGKILL at a random point leaves a clean prefix of what was queued.
    NSUInteger interrupted=0;
    BOOL prefixes=YES, intact=YES, opens=YES;
    for (int attempt=0;attempt<8;attempt++) {
        path=NewPath(root);
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSTask *child=[NSTask new];
        child.executableURL=[NSURL fileURLWithPath:@(program)];
        child.arguments=@[@"--writer-crash",path,[NSString stringWithFormat:@"%d",arc4random_uniform(40)]];
        if (![child launchAndReturnError:&error]) { prefixes=NO; break; }
        [child waitUntilExit];
        if (child.terminationReason!=NSTaskTerminationReasonUncaughtSignal) { prefixes=NO; continue; }
        NSArray *spaces=SavedSpaces(path), *visits=SavedVisits(path);
        for (NSUInteger i=0;i<spaces.count;i++) if (![spaces[i] isEqual:[NSString stringWithFormat:@"w%03lu",(unsigned long)i]]) prefixes=NO;
        for (NSUInteger i=0;i<visits.count;i++) if (![visits[i] hasSuffix:[NSString stringWithFormat:@"/%03lu",(unsigned long)i]]) prefixes=NO;
        // Each save precedes its visit, so a kill can separate at most that one pair.
        if (spaces.count<visits.count || spaces.count>visits.count+1) prefixes=NO;
        if (spaces.count>0 && spaces.count<(NSUInteger)CrashWrites) interrupted++;
        intact=intact && Integrity(path);
        LTStore *survivor=[[LTStore alloc]initWithPath:path error:&error];
        opens=opens && survivor && [survivor commit:^(LTProfile *p){ [p addSpace:@"w-next"]; } error:&error];
    }
    CHECK(prefixes,"a killed process leaves exactly a prefix of the queued saves and visits");
    CHECK(intact,"a killed process leaves a database that passes quick_check");
    CHECK(opens,"a profile reopens and saves after the writer was killed mid-queue");
    CHECK(interrupted>0,"the kill landed while writes were queued");
    [NSNotificationCenter.defaultCenter removeObserver:changed];
    [NSNotificationCenter.defaultCenter removeObserver:failedWrites];
}
int main(int argc,char **argv) { @autoreleasepool {
    if (argc == 4 && !strcmp(argv[1],"--writer-crash")) return RunWriterCrashChild(argv[2],atoi(argv[3]));
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
    [store waitForWrites];
    CHECK([store deleteHistoryURL:@"https://example.invalid/one" error:&error] && [store history:@"" limit:10].count==1,"single-history-entry deletion preserves unrelated entries");
    store=nil;
    CHECK([LTStore recoverProfileAtPath:historyPath preservedPath:nil error:&error],"single-entry deletion creates usable updated backup");
    store=[[LTStore alloc]initWithPath:historyPath error:&error];
    CHECK([store history:@"one" limit:10].count==0 && [store history:@"two" limit:10].count==1,"updated recovery honors individual history deletion"); store=nil;
    NSString *privatePath=NewPath(root);
    LTStore *privateStore=[[LTStore alloc]initWithPath:nil error:&error];
    CHECK(privateStore.privateMode && !privateStore.backupError && ![NSFileManager.defaultManager fileExistsAtPath:privatePath],"private profile remains ephemeral without disk backups");
    WriterTests(root,argv[0]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    sqlite3_vfs_unregister(&faults);
    printf("\n%d passed, %d failed\n",passed,failed);
    return failed ? 1 : 0;
}}
