#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *LTUUID(void);
FOUNDATION_EXPORT NSError *LTError(NSString *message);
FOUNDATION_EXPORT BOOL LTValidURL(NSString *url);
FOUNDATION_EXPORT NSString *LTURLFromInput(NSString *input, NSString *provider);
FOUNDATION_EXPORT NSString *LTSearchURL(NSString *query, NSString *provider);

@interface LTNode : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *kind; // folder, pinned, temporary, favorite
@property (nonatomic, copy) NSString *spaceID;
@property (nonatomic, copy) NSString *parentID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *pinnedURL;
@property (nonatomic, copy) NSString *favicon;
@property (nonatomic) NSInteger order;
@property (nonatomic) BOOL expanded;
@property (nonatomic) double lastUsed;
@property (nonatomic, readonly) NSString *displayTitle;
+ (instancetype)fromJSON:(NSDictionary *)json;
- (NSDictionary *)JSON;
@end

@interface LTSpace : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *selectedID;
+ (instancetype)fromJSON:(NSDictionary *)json;
- (NSDictionary *)JSON;
@end

@interface LTProfile : NSObject
@property (nonatomic) NSMutableArray<LTSpace *> *spaces;
@property (nonatomic) NSMutableArray<LTNode *> *nodes;
@property (nonatomic) NSMutableDictionary *settings;
@property (nonatomic) NSMutableArray<NSDictionary *> *windows;
@property (nonatomic, copy) NSString *activeSpaceID;
+ (instancetype)fresh;
+ (nullable instancetype)fromJSON:(NSDictionary *)json error:(NSError **)error;
- (NSDictionary *)JSON;
- (nullable LTNode *)node:(NSString *)identifier;
- (nullable LTSpace *)space:(NSString *)identifier;
- (NSArray<LTNode *> *)children:(NSString *)parent
                          space:(NSString *)space
                           kind:(nullable NSString *)kind;
- (LTSpace *)addSpace:(NSString *)name;
- (LTNode *)addNode:(NSString *)kind
              title:(NSString *)title
                url:(NSString *)url
              space:(NSString *)space
             parent:(NSString *)parent;
- (BOOL)moveNode:(NSString *)identifier
           space:(NSString *)space
          parent:(NSString *)parent
           index:(NSInteger)index
           error:(NSError **)error;
- (void)removeNode:(NSString *)identifier;
- (void)removeSpace:(NSString *)identifier;
- (BOOL)validate:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
