// FQUpdate.h - is a newer uFits out? Shared by the app and the preview.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The app's settings, in the app and in the preview extension alike:
/// "Check for updates", what was seen out there, the stretch of previews.
NSUserDefaults *FQSettings(void);

/// Looks, at most once a day and in the background, at the release that
/// GitHub's .../releases/latest leads to, and remembers what it saw in the
/// app's settings. Only the app looks (Quick Look keeps its previews off
/// the network); the preview extension reads what it saw.
@interface FQUpdate : NSObject
/// The version running, e.g. "0.0.3".
@property(class, nonatomic, readonly) NSString *currentVersion;
/// The latest version seen out there, if it was looked for.
@property(class, nonatomic, readonly, nullable) NSString *latestVersion;
/// A newer version seen out there, unless the user skipped it; else nil.
@property(class, nonatomic, readonly, nullable) NSString *availableVersion;
/// "Check for updates" (the app's setting; on unless turned off).
@property(class, nonatomic) BOOL enabled;
/// A version the user chose to skip (the app's setting).
@property(class, nonatomic, copy, nullable) NSString *skippedVersion;
/// Looks again when a day has passed since the last look, or when forced
/// (in an extension it only answers with what was seen). done, on the
/// main queue: a newer version (skipped or not), or nil; an error when it
/// could not look.
+ (void)check:(BOOL)force done:(nullable void (^)(NSString *_Nullable newer, NSError *_Nullable error))done;
/// Whether a look is due (a day since the last one, and looking is on).
@property(class, nonatomic, readonly) BOOL due;
/// Whether version a is later than b ("0.0.10" is later than "0.0.9").
+ (BOOL)version:(NSString *)a isNewerThan:(NSString *)b;
/// The page of a release.
+ (NSURL *)releasePage:(NSString *)version;
/// The installer that comes with a release.
+ (NSURL *)installer:(NSString *)version;
@end

NS_ASSUME_NONNULL_END
