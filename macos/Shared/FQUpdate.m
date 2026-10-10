// FQUpdate.m - is a newer uFits out? See FQUpdate.h.

#import "FQUpdate.h"

static NSString *const kRepo = @"lmytime/uFits";
static NSString *const kLatestKey = @"FQUpdateLatest";     // last version seen out there
static NSString *const kCheckedKey = @"FQUpdateChecked";   // when it was seen
static NSString *const kTriedKey = @"FQUpdateTried";       // when a look last began
static NSString *const kEnabledKey = @"FQCheckForUpdates";
static NSString *const kSkippedKey = @"FQSkippedVersion";

static BOOL FQInExtension(void)
{
    return [NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"];
}

/// The app's settings, where what was seen is kept too: its own defaults in
/// the app; in an extension (whose identifier is the app's and a last
/// part, ".Preview"), the app's, which its sandbox lets it read and write
/// (Preview.entitlements).
NSUserDefaults *FQSettings(void)
{
    static NSUserDefaults *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *ident = NSBundle.mainBundle.bundleIdentifier;
        if (FQInExtension() && ident.pathExtension.length)
            settings = [[NSUserDefaults alloc] initWithSuiteName:ident.stringByDeletingPathExtension];
        if (!settings)
            settings = NSUserDefaults.standardUserDefaults;
    });
    return settings;
}

static BOOL FQRecent(id date, NSTimeInterval seconds)
{
    if (![date isKindOfClass:NSDate.class])
        return NO;
    NSTimeInterval age = -[(NSDate *)date timeIntervalSinceNow];
    return age >= 0 && age < seconds;
}

@implementation FQUpdate

+ (NSString *)currentVersion
{
    NSString *v = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return [v isKindOfClass:NSString.class] && v.length ? v : @"0";
}

+ (BOOL)enabled
{
    id on = [FQSettings() objectForKey:kEnabledKey];
    return on ? [on boolValue] : YES;
}

+ (void)setEnabled:(BOOL)enabled
{
    [FQSettings() setBool:enabled forKey:kEnabledKey];
}

+ (NSString *)skippedVersion
{
    NSString *v = [FQSettings() stringForKey:kSkippedKey];
    return v.length ? v : nil;
}

+ (void)setSkippedVersion:(NSString *)version
{
    if (version.length)
        [FQSettings() setObject:version forKey:kSkippedKey];
    else
        [FQSettings() removeObjectForKey:kSkippedKey];
}

+ (NSString *)latestVersion
{
    NSString *latest = [FQSettings() stringForKey:kLatestKey];
    return latest.length ? latest : nil;
}

/// The newer version last seen, skipped or not.
+ (NSString *)newerSeen
{
    NSString *latest = self.latestVersion;
    return latest && [self version:latest isNewerThan:self.currentVersion] ? latest : nil;
}

+ (NSString *)availableVersion
{
    NSString *newer = self.enabled ? [self newerSeen] : nil;
    return newer && ![newer isEqualToString:self.skippedVersion ?: @""] ? newer : nil;
}

+ (BOOL)version:(NSString *)a isNewerThan:(NSString *)b
{
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."], *pb = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(pa.count, pb.count); i++) {
        NSInteger x = i < pa.count ? pa[i].integerValue : 0, y = i < pb.count ? pb[i].integerValue : 0;
        if (x != y)
            return x > y;
    }
    return NO;
}

+ (NSURL *)releasePage:(NSString *)version
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/releases/tag/v%@", kRepo, version]];
}

+ (NSURL *)installer:(NSString *)version
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/releases/download/v%@/install.sh",
                                                           kRepo, version]];
}

+ (BOOL)due
{
    // Once a day; after a failed look, again after an hour.
    NSUserDefaults *state = FQSettings();
    return self.enabled && !FQRecent([state objectForKey:kCheckedKey], 24 * 3600) &&
           !FQRecent([state objectForKey:kTriedKey], 3600);
}

+ (void)check:(BOOL)force done:(void (^)(NSString *, NSError *))done
{
    // One look at a time (on the main thread); whoever asks meanwhile gets
    // its answer.
    static BOOL busy;
    static NSMutableArray<void (^)(NSString *, NSError *)> *waiting;
    NSUserDefaults *state = FQSettings();
    if (FQInExtension() || (!busy && !force && !self.due)) {
        if (done)
            dispatch_async(dispatch_get_main_queue(), ^{
                done([self newerSeen], nil);
            });
        return;
    }
    if (!waiting)
        waiting = [NSMutableArray array];
    if (done)
        [waiting addObject:[done copy]];
    if (busy)
        return;
    busy = YES;
    [state setObject:[NSDate date] forKey:kTriedKey];
    // .../releases/latest leads to .../releases/tag/vX.Y.Z: no API (and no
    // limit on how often), only where it leads.
    NSURL *latest = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/releases/latest", kRepo]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:latest
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20];
    req.HTTPMethod = @"HEAD";
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    (void)data;
                    NSString *tag = response.URL.lastPathComponent ?: @"";
                    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                           ? ((NSHTTPURLResponse *)response).statusCode
                                           : 0;
                    NSString *version = nil;
                    if (!error && status == 200 && tag.length > 1 && [tag hasPrefix:@"v"] &&
                        [NSCharacterSet.decimalDigitCharacterSet characterIsMember:[tag characterAtIndex:1]])
                        version = [tag substringFromIndex:1];
                    if (!version && !error)
                        error = [NSError errorWithDomain:@"uFits"
                                                    code:1
                                                userInfo:@{
                                                    NSLocalizedDescriptionKey : [NSString
                                                        stringWithFormat:@"No release found at %@ (HTTP %ld).",
                                                                         latest.absoluteString, (long)status]
                                                }];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        busy = NO;
                        if (version) {
                            [state setObject:version forKey:kLatestKey];
                            [state setObject:[NSDate date] forKey:kCheckedKey];
                        }
                        NSLog(@"uFits: the latest release is %@; this is %@%@", version ?: @"unknown",
                              self.currentVersion,
                              version ? @"" : [@" — " stringByAppendingString:error.localizedDescription ?: @"?"]);
                        NSArray<void (^)(NSString *, NSError *)> *calls = [waiting copy];
                        [waiting removeAllObjects];
                        for (void (^call)(NSString *, NSError *) in calls)
                            call([self newerSeen], version ? nil : error);
                    });
                }] resume];
    [session finishTasksAndInvalidate];
}

@end
