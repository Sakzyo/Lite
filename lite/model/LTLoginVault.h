#import <Foundation/Foundation.h>

// One authenticated, encrypted file per profile. Transactions hold a filesystem
// lock and reload the file so separate windows/processes cannot lose updates.
@interface LTLoginVault : NSObject
- (instancetype)initWithProfilePath:(NSString *)path keyService:(NSString *)service;
- (BOOL)withRecords:(BOOL (^)(NSMutableArray<NSDictionary *> *records, BOOL *changed,
                              NSError **error))action
        afterCommit:(BOOL (^)(NSError **error))cleanup
              error:(NSError **)error;
@end
