#import "LJObjCExceptionCatcher.h"

NSErrorDomain const LJObjCExceptionErrorDomain = @"localjam_audio.objc_exception";

@implementation LJObjCExceptionCatcher

+ (BOOL)catchingBlock:(NS_NOESCAPE void (^)(void))block
                error:(NSError *_Nullable *_Nullable)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    // Objects the block had in flight leak (ARC is not exception-safe without
    // -fobjc-arc-exceptions, which a Swift package cannot set for a
    // dependency). A few leaked objects on a path that used to be a crash is
    // the right trade.
    if (error != NULL) {
      NSString *reason = exception.reason ?: exception.name;
      *error = [NSError errorWithDomain:LJObjCExceptionErrorDomain
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : reason,
                                 @"exceptionName" : exception.name,
                               }];
    }
    return NO;
  }
}

@end
