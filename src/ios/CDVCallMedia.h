#import <AVFoundation/AVFoundation.h>
#import "CDVCallKeep.h"

@interface CDVCallMedia : NSObject

+ (void)keepRunning:(BOOL)on;
+ (void)prepareAudioSession;
+ (void)audioSessionDidActivate:(AVAudioSession *)session;
+ (void)audioSessionDidDeactivate:(AVAudioSession *)session;

@end

@interface CDVCallKeep (Media)

- (void)rtcCreate:(CDVInvokedUrlCommand *)command;
- (void)rtcClose:(CDVInvokedUrlCommand *)command;
- (void)rtcSetConfiguration:(CDVInvokedUrlCommand *)command;
- (void)rtcCreateOffer:(CDVInvokedUrlCommand *)command;
- (void)rtcCreateAnswer:(CDVInvokedUrlCommand *)command;
- (void)rtcSetLocalDescription:(CDVInvokedUrlCommand *)command;
- (void)rtcSetRemoteDescription:(CDVInvokedUrlCommand *)command;
- (void)rtcAddIceCandidate:(CDVInvokedUrlCommand *)command;
- (void)rtcAddTrack:(CDVInvokedUrlCommand *)command;
- (void)rtcAddTransceiver:(CDVInvokedUrlCommand *)command;
- (void)rtcReplaceTrack:(CDVInvokedUrlCommand *)command;
- (void)rtcSetDirection:(CDVInvokedUrlCommand *)command;
- (void)rtcRestartIce:(CDVInvokedUrlCommand *)command;
- (void)rtcGetStats:(CDVInvokedUrlCommand *)command;
- (void)rtcGetUserMedia:(CDVInvokedUrlCommand *)command;
- (void)rtcTrackEnabled:(CDVInvokedUrlCommand *)command;
- (void)rtcTrackStop:(CDVInvokedUrlCommand *)command;
- (void)rtcRender:(CDVInvokedUrlCommand *)command;
- (void)keepRunning:(CDVInvokedUrlCommand *)command;

@end
