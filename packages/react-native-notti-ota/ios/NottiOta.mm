#import <NottiOtaSpec/NottiOtaSpec.h>
#import <React/RCTBundleManager.h>

#if __has_include(<NottiOta/NottiOta-Swift.h>)
#import <NottiOta/NottiOta-Swift.h>
#else
#import "NottiOta-Swift.h"
#endif

// Declared here rather than in a header: the codegen spec is C++, and a public header importing it
// would make the pod's Swift module unimportable (the Expo adapter and the tests import it).
@interface NottiOta : NSObject <NativeNottiOtaSpec>
@end

// Runs at image load, before UIApplicationMain: the launch hooks must see the first activation.
__attribute__((constructor)) static void NottiOtaStartAtLaunch(void)
{
  [NottiOTA startAtLaunch];
}

@implementation NottiOta

@synthesize bundleManager = _bundleManager;

RCT_EXPORT_MODULE()

- (void)setBundleManager:(RCTBundleManager *)bundleManager
{
  _bundleManager = bundleManager;
  [NottiOTA hostLoadedBundle:bundleManager.bundleURL];
}

- (void)getCurrentRelease:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@{@"releaseId" : [NSNull null], @"isEmbedded" : @YES});
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeNottiOtaSpecJSI>(params);
}

@end
