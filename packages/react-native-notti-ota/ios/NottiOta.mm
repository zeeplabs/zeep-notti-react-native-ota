#import <NottiOtaSpec/NottiOtaSpec.h>

// Declared here rather than in a header: the codegen spec is C++, and a public header importing it
// would make the pod's Swift module unimportable (the Expo adapter and the tests import it).
@interface NottiOta : NSObject <NativeNottiOtaSpec>
@end

@implementation NottiOta

RCT_EXPORT_MODULE()

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
