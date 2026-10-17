#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain of the NSError an Objective-C exception is converted into.
FOUNDATION_EXPORT NSErrorDomain const LJObjCExceptionErrorDomain;

/// Converts Objective-C exceptions raised inside a block into NSErrors.
///
/// AVFAudio reports many failures by raising NSException rather than
/// returning an error — `AVAudioPlayerNode.play(at:)` when the engine stopped
/// a moment earlier ("required condition is false: _engine->IsRunning()"),
/// when the player has not seen an IO cycle, `scheduleSegment` with zero
/// frames, `AVAudioEngine.connect` with a format a node rejects. Swift cannot
/// catch those, so an unlucky route change or an odd input file would take
/// the whole app down. Every such call in LocaljamAudioPlugin.swift goes
/// through this wrapper and surfaces as a FlutterError / playbackError
/// instead.
///
/// Lives in its own target because a Swift Package target cannot mix Swift
/// and Objective-C sources.
@interface LJObjCExceptionCatcher : NSObject

/// Runs `block`; returns NO and fills `error` if it raised an NSException.
+ (BOOL)catchingBlock:(NS_NOESCAPE void (^)(void))block
                error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(catching(_:));

@end

NS_ASSUME_NONNULL_END
