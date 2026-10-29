#import <Foundation/Foundation.h>

/// Runs `block`, turning an Objective-C exception into an NSError. AVAudioEngine reports some failures (a tap whose
/// format no longer matches the microphone while AirPods switch modes) as exceptions, which Swift cannot catch: AppKit
/// swallowed them mid-task, which left Swift's executor state corrupt and crashed the recorder a second later.
BOOL JRCatchException(NS_NOESCAPE void (^block)(void), NSError **error);
