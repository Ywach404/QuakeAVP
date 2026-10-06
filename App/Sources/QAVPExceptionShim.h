//
//  QAVPExceptionShim.h
//
//  Swift cannot catch an Objective-C NSException, and AVAudioEngine's
//  -connect:to:format: raises one (not a Swift error) when the audio graph
//  rejects the connection -- which is exactly what happens after AURemoteIO
//  fails to create its session. Without this, a failed audio bring-up crashes
//  the whole app instead of logging and moving on. This wraps a block in
//  @try/@catch so the failure is recoverable and the game plays on silent.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns YES if it completed, NO if it raised an NSException,
/// in which case `reason` is set to the exception's reason (if any).
BOOL QAVPTry(void (NS_NOESCAPE ^block)(void), NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
