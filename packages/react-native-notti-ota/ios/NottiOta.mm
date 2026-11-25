#import "NottiOta.h"

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
