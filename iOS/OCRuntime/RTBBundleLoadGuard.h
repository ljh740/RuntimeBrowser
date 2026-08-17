//
//  RTBBundleLoadGuard.h
//  OCRuntime
//
//  Loading a framework is not crash-safe: a +load method or a constructor may take the app down,
//  and which frameworks do changes with every OS version. The bundle being loaded is remembered
//  before each load; if it is still remembered at the next launch, the app crashed while loading
//  it and it goes to the list of the bundles that "Load All" skips.
//

#import <Foundation/Foundation.h>

@interface RTBBundleLoadGuard : NSObject

// The bundle whose loading crashed the previous run, added to the skipped bundles; nil if none. Consumes the marker.
+ (NSString *)bundlePathThatCrashedPreviousLaunch;

+ (BOOL)shouldSkipBundle:(NSBundle *)bundle;

// to call around -[NSBundle load]
+ (void)willLoadBundle:(NSBundle *)bundle;
+ (void)didLoadBundle:(NSBundle *)bundle; // a successful load also removes the bundle from the skipped ones

+ (NSArray *)skippedBundlePaths; // relative to the system root, eg. /System/Library/PrivateFrameworks/Foo.framework

@end
