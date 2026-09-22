#import "LTGitHub.h"
static BOOL Matches(NSString *value, NSString *pattern) {
    return [value isKindOfClass:NSString.class] &&
        [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
NSString *LTGitHubQuery(NSDictionary *configuration, NSError **error) {
    if (![configuration isKindOfClass:NSDictionary.class]) {
        if (error) *error = LTError(@"Invalid GitHub Live Folder settings.");
        return nil;
    }
    NSString *user = configuration[@"username"], *repo = configuration[@"repository"];
    NSString *mode = configuration[@"mode"], *draft = configuration[@"draft"];
    if (![mode isKindOfClass:NSString.class] || ![user isKindOfClass:NSString.class] ||
        ![repo isKindOfClass:NSString.class] || ![draft isKindOfClass:NSString.class]) {
        if (error) *error = LTError(@"Invalid GitHub Live Folder settings.");
        return nil;
    }
    BOOL validUser = Matches(user, @"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$");
    BOOL validRepo = Matches(repo, @"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$");
    NSDictionary *qualifiers = @{@"authored": @"author", @"review": @"review-requested", @"assigned": @"assignee"};
    if (![configuration isKindOfClass:NSDictionary.class] ||
        (![mode isEqual:@"repository"] && (!validUser || !qualifiers[mode])) ||
        ([mode isEqual:@"repository"] && !validRepo) ||
        (![repo isKindOfClass:NSString.class] || (repo.length && !validRepo)) ||
        ![@[@"all", @"ready", @"draft"] containsObject:draft ?: @""]) {
        if (error) *error = LTError(@"Enter a GitHub username and optionally owner/repository. The repository filter requires owner/repository.");
        return nil;
    }
    NSMutableString *query = [@"is:pr is:open" mutableCopy];
    if (![mode isEqual:@"repository"])
        [query appendFormat:@" %@:%@", qualifiers[mode], user];
    if (repo.length) [query appendFormat:@" repo:%@", repo];
    if (![draft isEqual:@"all"]) [query appendFormat:@" draft:%@", [draft isEqual:@"draft"] ? @"true" : @"false"];
    return query;
}
NSArray<NSDictionary *> *LTGitHubPullRequests(NSDictionary *response, NSError **error) {
    if (![response isKindOfClass:NSDictionary.class] ||
        ![response[@"items"] isKindOfClass:NSArray.class] ||
        ![response[@"total_count"] isKindOfClass:NSNumber.class] ||
        ![response[@"incomplete_results"] isKindOfClass:NSNumber.class] ||
        [response[@"incomplete_results"] boolValue] || [response[@"total_count"] integerValue] > 1000) {
        if (error) *error = LTError(@"GitHub returned incomplete results. Narrow the repository/filter and refresh. Existing tabs have been kept.");
        return nil;
    }
    NSMutableArray *pulls = [NSMutableArray new];
    for (NSDictionary *item in response[@"items"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"pull_request"] isKindOfClass:NSDictionary.class] ||
            ![item[@"title"] isKindOfClass:NSString.class] ||
            !Matches(item[@"html_url"], @"^https://github\\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$")) {
            if (error) *error = LTError(@"GitHub returned an unexpected pull-request entry. Existing tabs have been kept.");
            return nil;
        }
        NSURL *url = [NSURL URLWithString:item[@"html_url"]];
        NSArray *parts = url.pathComponents;
        NSString *title = [NSString stringWithFormat:@"%@/%@ #%@ — %@", parts[1], parts[2], parts.lastObject, item[@"title"]];
        [pulls addObject:@{@"url": item[@"html_url"], @"title": title}];
    }
    return pulls;
}
void LTApplyGitHubPullRequests(LTProfile *profile, NSString *folderID, NSArray<NSDictionary *> *pulls, NSSet<NSString *> *openIDs) {
    LTNode *folder = [profile node:folderID];
    NSDictionary *config = profile.settings[@"githubLiveFolders"][folderID];
    if (!config || ![folder.kind isEqual:@"folder"]) return;
    NSDictionary *previous = config[@"items"] ?: @{};
    NSMutableDictionary *current = [NSMutableDictionary new];
    NSInteger order = 0;
    for (NSDictionary *pull in pulls) {
        NSString *url = pull[@"url"];
        if (current[url]) continue;
        LTNode *node = [profile node:previous[url]];
        if (![node.parentID isEqual:folderID]) node = nil;
        if (!node) node = [profile addNode:@"pinned" title:pull[@"title"] url:url space:folder.spaceID parent:folderID];
        node.title = pull[@"title"];
        node.order = order++;
        current[url] = node.identifier;
    }
    for (NSString *url in previous) {
        LTNode *node = [profile node:previous[url]];
        if (!node || current[url] || ![node.parentID isEqual:folderID]) continue;
        if ([openIDs containsObject:node.identifier]) {
            node.kind = @"temporary";
            node.parentID = @"";
        } else [profile removeNode:node.identifier];
    }
    NSMutableDictionary *updated = [config mutableCopy];
    updated[@"items"] = current;
    updated[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    NSMutableDictionary *folders = [profile.settings[@"githubLiveFolders"] mutableCopy];
    folders[folderID] = updated;
    profile.settings[@"githubLiveFolders"] = folders;
}
@implementation LTGitHub {
    LTStore *_store;
    NSURLSession *_session;
    NSTimer *_timer;
    NSMutableDictionary<NSString *, NSURLSessionDataTask *> *_tasks;
    NSMutableDictionary<NSString *, NSString *> *_statuses;
    NSMutableDictionary<NSString *, NSString *> *_generations;
}
- (instancetype)initWithStore:(LTStore *)store logins:(LTLoginStore *)logins {
    if ((self = [super init])) {
        _store = store;
        _logins = logins;
        _tasks = [NSMutableDictionary new];
        _statuses = [NSMutableDictionary new];
        _generations = [NSMutableDictionary new];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil;
        configuration.URLCache = nil;
        configuration.timeoutIntervalForRequest = 25;
        configuration.timeoutIntervalForResource = 40;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    }
    return self;
}
- (void)start {
    if (_store.privateMode || _timer) return;
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:300 repeats:YES block:^(NSTimer *timer) { [weak refreshAll]; }];
    [self refreshAll];
}
- (void)stop {
    [_timer invalidate]; _timer = nil;
    for (NSURLSessionDataTask *task in _tasks.allValues) [task cancel];
    [_tasks removeAllObjects];
    [_generations removeAllObjects];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Authorization is sent only to the fixed GitHub API origin, never a redirect.
    completionHandler(nil);
}
- (NSString *)statusForFolder:(NSString *)identifier {
    if (_statuses[identifier]) return _statuses[identifier];
    NSNumber *updated = _store.profile.settings[@"githubLiveFolders"][identifier][@"updated"];
    return updated ? [@"Updated " stringByAppendingString:[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:updated.doubleValue]
        dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]] : @"Not refreshed yet";
}
- (void)setStatus:(NSString *)status folder:(NSString *)identifier {
    _statuses[identifier] = status;
    [NSNotificationCenter.defaultCenter postNotificationName:@"LTGitHubChanged" object:self];
}
- (void)refreshAll {
    NSDictionary *folders = _store.profile.settings[@"githubLiveFolders"];
    if (![folders isKindOfClass:NSDictionary.class]) return;
    for (NSString *identifier in folders)
        if ([_store.profile node:identifier] && !_tasks[identifier]) [self refreshFolder:identifier];
}
- (void)refreshFolder:(NSString *)identifier {
    if (_store.privateMode) return;
    NSDictionary *config = _store.profile.settings[@"githubLiveFolders"][identifier];
    if (!config || ![_store.profile node:identifier]) return;
    [_tasks[identifier] cancel];
    [_tasks removeObjectForKey:identifier];
    NSError *error = nil;
    NSString *query = LTGitHubQuery(config, &error);
    NSString *generation = LTUUID();
    _generations[identifier] = generation;
    if (!query) { [self setStatus:error.localizedDescription folder:identifier]; return; }
    NSString *token = [_logins githubToken:&error];
    if (!token) { [self setStatus:@"Unlock the GitHub token in Keychain, then refresh." folder:identifier]; return; }
    [self setStatus:@"Refreshing pull requests…" folder:identifier];
    [self fetchFolder:identifier query:query token:token page:1 pulls:[NSMutableArray new] generation:generation];
}
- (void)fetchFolder:(NSString *)identifier query:(NSString *)query token:(NSString *)token
    page:(NSInteger)page pulls:(NSMutableArray *)pulls generation:(NSString *)generation {
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://api.github.com/search/issues"];
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:query],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"updated"],
        [NSURLQueryItem queryItemWithName:@"order" value:@"desc"],
        [NSURLQueryItem queryItemWithName:@"per_page" value:@"100"],
        [NSURLQueryItem queryItemWithName:@"page" value:@(page).stringValue]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL];
    [request setValue:@"Lite-Browser" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    if (token.length) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    __weak typeof(self) weak = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        LTGitHub *owner = weak;
        if (!owner || ![owner->_generations[identifier] isEqual:generation]) return;
        [owner->_tasks removeObjectForKey:identifier];
        NSDictionary *config = owner->_store.profile.settings[@"githubLiveFolders"][identifier];
        if (!config || ![LTGitHubQuery(config, nil) isEqual:query] || ![owner->_store.profile node:identifier]) return;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSString *failure = nil;
        if (networkError) failure = @"GitHub could not be reached. Existing tabs are kept; refresh to retry.";
        else if (status == 401) failure = @"GitHub token was rejected. Edit this Live Folder to replace it.";
        else if (status == 403 || status == 429) failure = @"GitHub access or rate limit reached. Check token permissions or retry later.";
        else if (status != 200) failure = [NSString stringWithFormat:@"GitHub returned HTTP %ld. Check the username, repository and token access.", (long)status];
        else if (data.length > 32 * 1024 * 1024) failure = @"GitHub response was too large. Narrow the repository filter.";
        NSError *error = nil;
        NSDictionary *json = failure ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSArray *batch = json ? LTGitHubPullRequests(json, &error) : nil;
        if (!failure && !batch) failure = error.localizedDescription ?: @"GitHub returned an unreadable response.";
        if (failure) { [owner setStatus:failure folder:identifier]; return; }
        [pulls addObjectsFromArray:batch];
        NSInteger total = [json[@"total_count"] integerValue];
        if (pulls.count < total && batch.count == 100 && page < 10) {
            [owner fetchFolder:identifier query:query token:token page:page + 1 pulls:pulls generation:generation];
            return;
        }
        if (pulls.count != total || [NSSet setWithArray:[pulls valueForKey:@"url"]].count != pulls.count) {
            [owner setStatus:@"Results changed during refresh. Existing tabs are kept; refresh again." folder:identifier];
            return;
        }
        NSSet *open = owner.openIDs ? owner.openIDs() : [NSSet set];
        if (![owner->_store commit:^(LTProfile *profile) { LTApplyGitHubPullRequests(profile, identifier, pulls, open); } error:&error]) {
            [owner setStatus:error.localizedDescription folder:identifier]; return;
        }
        [owner->_statuses removeObjectForKey:identifier];
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTGitHubChanged" object:owner];
    }];
    _tasks[identifier] = task;
    [task resume];
}
@end
