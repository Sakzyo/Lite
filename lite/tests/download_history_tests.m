#import <Foundation/Foundation.h>
#import "../macos/LTDownloadHistory.h"
// The persistence tests exercise notifications from a deliberately minimal page
// double; real CEF download/network/quarantine behavior belongs to LTSmoke.
@interface LTPage : NSObject
@property BOOL privateMode;
@property NSString *contextIdentifier;
@property NSString *lastAction;
@property NSInteger lastDownload;
- (void)downloadAction:(NSString *)action identifier:(NSInteger)identifier;
@end
@implementation LTPage
- (void)downloadAction:(NSString *)action identifier:(NSInteger)identifier { _lastAction=action; _lastDownload=identifier; }
@end
static int passed,failed;
#define CHECK(condition,name) do {if(condition){passed++;printf("PASS %s\n",name);}else{failed++;fprintf(stderr,"FAIL %s (line %d)\n",name,__LINE__);}}while(0)
static NSMutableDictionary *Row(NSInteger identifier,BOOL active) {
    return [@{@"key":[NSString stringWithFormat:@"saved-%ld",(long)identifier],@"name":@"test.txt",@"path":@"/private/tmp/synthetic-download.txt",@"url":@"https://example.invalid/download",@"id":@(identifier),@"time":@(identifier),@"active":@(active),@"complete":@(!active),@"canceled":@NO,@"paused":@NO,@"percent":@(active?25:100),@"interrupted":@NO,@"canResume":@(active)} mutableCopy];
}
static NSData *Save(id rows,NSString *path) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    [data writeToFile:path atomically:YES]; return data;
}
static void Emit(LTPage *page,NSDictionary *row) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"LTDownloadChanged" object:page userInfo:row];
}
int main(void){@autoreleasepool{
    NSString *directory=[@"/private/tmp" stringByAppendingPathComponent:[@"lite-download-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[directory stringByAppendingPathComponent:@"Downloads.json"];
    Save(@[Row(1,NO),Row(2,YES)],path);
    LTDownloadHistory *history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];
    CHECK(history.rows.count==2 && !history.saveError,"completed and in-progress metadata load from disk");
    NSDictionary *interrupted=history.rows.firstObject;
    CHECK(![interrupted[@"active"] boolValue] && [interrupted[@"interrupted"] boolValue] && ![interrupted[@"canResume"] boolValue] && [interrupted[@"reason"] length],"restart turns active downloads into explicit interruption without fake resume");
    [history performAction:@"forget" download:history.rows.lastObject];
    [history flush]; history=nil;
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];
    CHECK(history.rows.count==1,"forget persists across restart"); history=nil;
    for(NSString *field in @[@"key",@"name",@"path",@"url",@"id",@"time",@"active",@"complete",@"canceled",@"paused",@"percent",@"interrupted",@"canResume",@"received",@"total",@"reason",@"status",@"securityError",@"quarantined",@"reasonCode"]){
        NSMutableDictionary *row=Row(3,NO);row[field]=[NSNull null];NSData *original=Save(@[row],path);
        @try {
            history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];[history flush];
            CHECK(history.saveError.length && [original isEqual:[NSData dataWithContentsOfFile:path]],"malformed download field is reported and original preserved");
        }@catch(NSException *exception){CHECK(NO,"malformed download field must not throw");}
        history=nil;
    }
    for(id value in @[[NSNull null],@"download",@42,@[]]){
        NSData *original=Save(@[value],path);history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];[history flush];
        CHECK(history.saveError.length && [original isEqual:[NSData dataWithContentsOfFile:path]],"nondictionary download record cannot silently overwrite saved history");history=nil;
    }
    NSMutableData *oversized=[NSMutableData dataWithLength:1024*1024+1];[oversized writeToFile:path atomically:YES];
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];[history flush];
    CHECK(history.saveError.length && [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]==oversized.length,"oversized download history is rejected without overwrite");history=nil;
    NSMutableArray *tail=[NSMutableArray new];
    for(NSInteger i=0;i<200;i++) [tail addObject:Row(i,NO)];
    [tail addObject:[NSNull null]];
    NSData *tailOriginal=Save(tail,path);
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];[history flush];
    CHECK(history.saveError.length && [tailOriginal isEqual:[NSData dataWithContentsOfFile:path]],"malformed records beyond retention limit still preserve damaged original");history=nil;
    NSData *empty=Save(@[],path);
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];
    LTPage *largePage=[LTPage new];largePage.contextIdentifier=@"regular";
    NSMutableDictionary *largeRow=Row(900,NO);largeRow[@"name"]=[@"x" stringByPaddingToLength:1024*1024 withString:@"x" startingAtIndex:0];
    Emit(largePage,largeRow);[history flush];
    CHECK(history.saveError.length && [empty isEqual:[NSData dataWithContentsOfFile:path]],"save limit prevents producing history too large for its own loader");history=nil;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    LTPage *regular=[LTPage new];regular.contextIdentifier=@"regular";
    LTPage *privateA=[LTPage new];privateA.contextIdentifier=@"private-a";privateA.privateMode=YES;
    LTPage *privateB=[LTPage new];privateB.contextIdentifier=@"private-b";privateB.privateMode=YES;
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];
    LTDownloadHistory *privateHistory=[[LTDownloadHistory alloc]initWithPath:nil contextIdentifier:@"private-a"];
    Emit(regular,Row(10,YES));Emit(privateA,Row(11,NO));Emit(privateB,Row(12,NO));
    CHECK(history.rows.count==1 && privateHistory.rows.count==1 && [history.rows[0][@"id"] integerValue]==10 && [privateHistory.rows[0][@"id"] integerValue]==11,"regular and separate private contexts cannot leak download metadata");
    [history performAction:@"pause" download:history.rows[0]];
    CHECK([regular.lastAction isEqual:@"pause"] && regular.lastDownload==10,"download action routes to exact owning page and identifier");
    __weak LTPage *weakPage=regular;
    Emit(regular,Row(10,NO));regular=nil;
    CHECK(!weakPage,"completed download releases owning page");
    regular=[LTPage new];regular.contextIdentifier=@"regular";
    Emit(regular,Row(10,NO));
    CHECK(history.rows.count==1,"same-session repeated event updates one download record");
    for(NSInteger i=20;i<245;i++) Emit(regular,Row(i,NO));
    CHECK(history.rows.count==200,"completed download retention stays bounded at 200");
    Emit(regular,Row(500,YES));
    CHECK(history.rows.count==201,"retention does not discard an active download");
    [history flush];history=nil;privateHistory=nil;
    history=[[LTDownloadHistory alloc]initWithPath:path contextIdentifier:nil];
    CHECK(history.rows.count==200 && !history.saveError,"bounded history survives disk round trip");
    CHECK([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFilePosixPermissions] integerValue]==0600,"saved download metadata is owner-only");
    history=nil;
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    printf("\n%d passed, %d failed\n",passed,failed);return failed?1:0;
}}
