// A call's media, run by libwebrtc in the app's own process.
//
// WKWebView captures and plays in WebKit's GPU process, under an audio session of its own, and while
// CallKit holds a call that session is outranked: the call is silent both ways (Apple DTS, forums
// thread 767949; WebKit bug 167788). Here the peer connection, the microphone, the camera and the
// playout live in this process, under the session CallKit activates - the page keeps the signalling
// and drives all of it through the commands below, with the same RTCPeerConnection surface a browser
// has. Video is drawn by native views placed under the webview where the page says its elements are.
//
// Everything here runs on the main queue: commands arrive there, and libwebrtc's callbacks are
// brought there before they touch any state or reach the page.

#import "CDVCallMedia.h"
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <WebRTC/WebRTC.h>

static id orNull(id value) { return value ?: [NSNull null]; }

static NSString *stringArg(NSArray *args, NSUInteger index)
{
    id value = index < args.count ? args[index] : nil;
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSDictionary *dictArg(NSArray *args, NSUInteger index)
{
    id value = index < args.count ? args[index] : nil;
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSString *directionString(RTCRtpTransceiverDirection direction)
{
    switch (direction) {
        case RTCRtpTransceiverDirectionSendRecv: return @"sendrecv";
        case RTCRtpTransceiverDirectionSendOnly: return @"sendonly";
        case RTCRtpTransceiverDirectionRecvOnly: return @"recvonly";
        case RTCRtpTransceiverDirectionInactive: return @"inactive";
        default: return @"stopped";
    }
}

static RTCRtpTransceiverDirection directionFrom(NSString *direction)
{
    if ([direction isEqualToString:@"sendonly"]) return RTCRtpTransceiverDirectionSendOnly;
    if ([direction isEqualToString:@"recvonly"]) return RTCRtpTransceiverDirectionRecvOnly;
    if ([direction isEqualToString:@"inactive"]) return RTCRtpTransceiverDirectionInactive;
    return RTCRtpTransceiverDirectionSendRecv;
}

static NSString *signalingString(RTCSignalingState state)
{
    switch (state) {
        case RTCSignalingStateStable: return @"stable";
        case RTCSignalingStateHaveLocalOffer: return @"have-local-offer";
        case RTCSignalingStateHaveLocalPrAnswer: return @"have-local-pranswer";
        case RTCSignalingStateHaveRemoteOffer: return @"have-remote-offer";
        case RTCSignalingStateHaveRemotePrAnswer: return @"have-remote-pranswer";
        default: return @"closed";
    }
}

static NSString *iceConnectionString(RTCIceConnectionState state)
{
    switch (state) {
        case RTCIceConnectionStateNew: return @"new";
        case RTCIceConnectionStateChecking: return @"checking";
        case RTCIceConnectionStateConnected: return @"connected";
        case RTCIceConnectionStateCompleted: return @"completed";
        case RTCIceConnectionStateFailed: return @"failed";
        case RTCIceConnectionStateDisconnected: return @"disconnected";
        default: return @"closed";
    }
}

static NSString *gatheringString(RTCIceGatheringState state)
{
    switch (state) {
        case RTCIceGatheringStateNew: return @"new";
        case RTCIceGatheringStateGathering: return @"gathering";
        default: return @"complete";
    }
}

static NSString *connectionString(RTCPeerConnectionState state)
{
    switch (state) {
        case RTCPeerConnectionStateNew: return @"new";
        case RTCPeerConnectionStateConnecting: return @"connecting";
        case RTCPeerConnectionStateConnected: return @"connected";
        case RTCPeerConnectionStateDisconnected: return @"disconnected";
        case RTCPeerConnectionStateFailed: return @"failed";
        default: return @"closed";
    }
}

static id descriptionDict(RTCSessionDescription *description)
{
    if (!description) return [NSNull null];
    return @{ @"type": [RTCSessionDescription stringForType:description.type], @"sdp": description.sdp };
}

static RTCConfiguration *configurationFrom(NSDictionary *config)
{
    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.bundlePolicy = RTCBundlePolicyMaxBundle;
    NSMutableArray *servers = [NSMutableArray array];
    for (id server in config[@"iceServers"]) {
        if (![server isKindOfClass:[NSDictionary class]]) continue;
        id urls = server[@"urls"] ?: server[@"url"];
        NSArray *list = [urls isKindOfClass:[NSArray class]] ? urls : ([urls isKindOfClass:[NSString class]] ? @[urls] : @[]);
        if (!list.count) continue;
        NSString *username = [server[@"username"] isKindOfClass:[NSString class]] ? server[@"username"] : nil;
        NSString *credential = [server[@"credential"] isKindOfClass:[NSString class]] ? server[@"credential"] : nil;
        [servers addObject:[[RTCIceServer alloc] initWithURLStrings:list username:username credential:credential]];
    }
    configuration.iceServers = servers;
    if ([config[@"iceTransportPolicy"] isEqual:@"relay"]) configuration.iceTransportPolicy = RTCIceTransportPolicyRelay;
    return configuration;
}


// A remote video track's frames: the first one says the picture is there, and a pause says it went -
// which is the only way a page learns that the far end turned its camera off.
@interface CDVFrameWatch : NSObject <RTCVideoRenderer>
@property (nonatomic, copy) NSString *trackId;
@property (nonatomic, copy) NSString *pcId;
@property (atomic) CFTimeInterval last;
@property (atomic) CGSize size;
@property (nonatomic) BOOL live;
@end

@implementation CDVFrameWatch
- (void)setSize:(CGSize)size { _size = size; }
- (void)renderFrame:(RTCVideoFrame *)frame { if (frame) self.last = CACurrentMediaTime(); }
@end


// The picture in the system's floating window, which shows no Metal view: frames are queued on an
// AVSampleBufferDisplayLayer, and a decoder's planes are packed into a pixel buffer first.
@interface CDVSampleView : UIView <RTCVideoRenderer>
@property (nonatomic, copy) void (^sized)(CGSize size);
@end

@implementation CDVSampleView {
    AVSampleBufferDisplayLayer *_display;
    RTCVideoRotation _rotation;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor blackColor];
    _display = [[AVSampleBufferDisplayLayer alloc] init];
    _display.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.layer addSublayer:_display];
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    BOOL sideways = _rotation == RTCVideoRotation_90 || _rotation == RTCVideoRotation_270;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _display.bounds = CGRectMake(0, 0, sideways ? size.height : size.width, sideways ? size.width : size.height);
    _display.position = CGPointMake(size.width / 2, size.height / 2);
    _display.affineTransform = CGAffineTransformMakeRotation(_rotation * M_PI / 180.0);
    [CATransaction commit];
}

- (void)setSize:(CGSize)size
{
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.sized) self.sized(size); });
}

static CVPixelBufferRef pixelsOf(RTCVideoFrame *frame)
{
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) return CVPixelBufferRetain(((RTCCVPixelBuffer *)frame.buffer).pixelBuffer);
    id<RTCI420Buffer> planes = [frame.buffer toI420];
    CVPixelBufferRef pixels = NULL;
    NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(NULL, planes.width, planes.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pixels, 0);
    uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0);
    size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0);
    for (int row = 0; row < planes.height; row++) memcpy(luma + row * lumaStride, planes.dataY + row * planes.strideY, planes.width);
    uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1);
    size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1);
    for (int row = 0; row < planes.chromaHeight; row++) {
        const uint8_t *u = planes.dataU + row * planes.strideU;
        const uint8_t *v = planes.dataV + row * planes.strideV;
        uint8_t *line = chroma + row * chromaStride;
        for (int col = 0; col < planes.chromaWidth; col++) {
            line[2 * col] = u[col];
            line[2 * col + 1] = v[col];
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    return pixels;
}

- (void)renderFrame:(RTCVideoFrame *)frame
{
    if (!frame) return;
    CVPixelBufferRef pixels = pixelsOf(frame);
    if (!pixels) return;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &format) == noErr
        && CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, format, &timing, &sample) == noErr) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        RTCVideoRotation rotation = frame.rotation;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (rotation != self->_rotation) {
                self->_rotation = rotation;
                [self setNeedsLayout];
            }
            if (self->_display.status == AVQueuedSampleBufferRenderingStatusFailed) [self->_display flush];
            [self->_display enqueueSampleBuffer:sample];
            CFRelease(sample);
        });
    }
    if (format) CFRelease(format);
    CVPixelBufferRelease(pixels);
}

@end


@interface CDVPeer : NSObject <RTCPeerConnectionDelegate>
@property (nonatomic, copy) NSString *pcId;
@property (nonatomic, copy) NSString *callbackId;
@property (nonatomic, strong) RTCPeerConnection *pc;
@end


@interface CDVCallMedia () <AVPictureInPictureControllerDelegate>
@property (nonatomic, weak) CDVCallKeep *plugin;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CDVPeer *> *peers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStreamTrack *> *tracks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCCameraVideoCapturer *> *capturers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMTLVideoView *> *views;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *viewTracks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CDVFrameWatch *> *watches;
@property (nonatomic, strong) NSTimer *watchTimer;
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, strong) AVPictureInPictureVideoCallViewController *pipContent;
@property (nonatomic, strong) CDVSampleView *pipView;
@property (nonatomic, strong) RTCVideoTrack *pipTrack;
@property (nonatomic, copy) NSString *pipViewId;
@property (nonatomic, copy) NSString *pipCallbackId;
@property (nonatomic) BOOL pipShowing;
+ (instancetype)shared;
- (void)emit:(CDVPeer *)peer event:(NSString *)event extra:(NSDictionary *)extra;
- (NSDictionary *)stateOf:(CDVPeer *)peer;
- (void)startWatching;
- (void)authorize:(AVMediaType)type then:(void (^)(BOOL granted))done;
- (RTCVideoTrack *)cameraTrack:(NSString *)facing;
- (RTCMTLVideoView *)viewFor:(NSString *)viewId in:(UIView *)webView;
- (void)detach:(NSString *)viewId;
- (void)pipFor:(NSString *)viewId track:(RTCVideoTrack *)track in:(UIView *)webView callback:(NSString *)callbackId;
- (void)pipOff;
@end


@implementation CDVPeer

- (void)main:(dispatch_block_t)block { dispatch_async(dispatch_get_main_queue(), block); }

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged
{
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"signalingstatechange" extra:nil]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection
{
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"negotiationneeded" extra:nil]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState
{
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"iceconnectionstatechange" extra:nil]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState
{
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"icegatheringstatechange" extra:nil]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState
{
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"connectionstatechange" extra:nil]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate
{
    NSDictionary *body = @{ @"candidate": @{ @"candidate": candidate.sdp, @"sdpMid": orNull(candidate.sdpMid), @"sdpMLineIndex": @(candidate.sdpMLineIndex) } };
    [self main:^{ [[CDVCallMedia shared] emit:self event:@"icecandidate" extra:body]; }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddReceiver:(RTCRtpReceiver *)rtpReceiver streams:(NSArray<RTCMediaStream *> *)mediaStreams
{
    RTCMediaStreamTrack *track = rtpReceiver.track;
    if (!track) return;
    NSMutableArray *streamIds = [NSMutableArray array];
    for (RTCMediaStream *stream in mediaStreams) [streamIds addObject:stream.streamId];
    NSString *receiverId = rtpReceiver.receiverId;
    [self main:^{
        CDVCallMedia *media = [CDVCallMedia shared];
        media.tracks[track.trackId] = track;
        if ([track.kind isEqualToString:kRTCMediaStreamTrackKindVideo] && !media.watches[track.trackId]) {
            CDVFrameWatch *watch = [[CDVFrameWatch alloc] init];
            watch.trackId = track.trackId;
            watch.pcId = self.pcId;
            [(RTCVideoTrack *)track addRenderer:watch];
            media.watches[track.trackId] = watch;
            [media startWatching];
        }
        NSInteger index = -1;
        NSArray<RTCRtpTransceiver *> *transceivers = self.pc.transceivers;
        for (NSUInteger i = 0; i < transceivers.count; i++) {
            if ([transceivers[i].receiver.receiverId isEqualToString:receiverId]) index = (NSInteger)i;
        }
        [media emit:self event:@"track" extra:@{ @"trackId": track.trackId, @"kind": track.kind, @"streamIds": streamIds, @"transceiver": @(index) }];
    }];
}

@end


@implementation CDVCallMedia

+ (instancetype)shared
{
    static CDVCallMedia *media;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ media = [[CDVCallMedia alloc] init]; });
    return media;
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    RTCInitializeSSL();
    [RTCAudioSession sharedInstance].useManualAudio = YES;
    _factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:[[RTCDefaultVideoEncoderFactory alloc] init]
                                                         decoderFactory:[[RTCDefaultVideoDecoderFactory alloc] init]];
    _peers = [NSMutableDictionary dictionary];
    _tracks = [NSMutableDictionary dictionary];
    _capturers = [NSMutableDictionary dictionary];
    _views = [NSMutableDictionary dictionary];
    _viewTracks = [NSMutableDictionary dictionary];
    _watches = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark - keeping the app running

// A remote session has to survive the operator switching apps for a moment, and iOS keeps an app
// running in the background only while it is playing audio. So while a session is live this plays
// silence, mixed with everything else so it interrupts nothing. A call needs none of it - CallKit
// keeps a call running - and the call owns the session, so the silence steps aside for one and
// comes back when the call's audio ends.
static NSInteger keepWanted = 0;
static BOOL callAudio = NO;
static AVAudioEngine *keepEngine = nil;

+ (void)startKeeping
{
    if (keepEngine || keepWanted <= 0 || callAudio) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *player = [[AVAudioPlayerNode alloc] init];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:8000 channels:1];
    AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:8000];
    silence.frameLength = 8000;
    memset(silence.floatChannelData[0], 0, sizeof(float) * 8000);
    [engine attachNode:player];
    [engine connect:player to:engine.mainMixerNode format:format];
    if (![engine startAndReturnError:nil]) return;
    [player scheduleBuffer:silence atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [player play];
    keepEngine = engine;
}

+ (void)stopKeeping
{
    if (!keepEngine) return;
    [keepEngine stop];
    keepEngine = nil;
    if (!callAudio) [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

+ (void)keepRunning:(BOOL)on
{
    keepWanted = MAX(0, keepWanted + (on ? 1 : -1));
    if (keepWanted > 0) [self startKeeping];
    else [self stopKeeping];
}

#pragma mark - audio, handed over by CallKit

// CallKit asks for the session to be configured before a call is reported and activated by CallKit
// alone. libwebrtc runs in manual-audio mode, so its audio unit starts only once CallKit says so.
+ (void)prepareAudioSession
{
    [self stopKeeping];
    callAudio = YES;
    RTCAudioSession *session = [RTCAudioSession sharedInstance];
    session.useManualAudio = YES;
    [session lockForConfiguration];
    [session setConfiguration:[RTCAudioSessionConfiguration webRTCConfiguration] error:nil];
    [session unlockForConfiguration];
}

+ (void)audioSessionDidActivate:(AVAudioSession *)audioSession
{
    RTCAudioSession *session = [RTCAudioSession sharedInstance];
    session.useManualAudio = YES;
    [session audioSessionDidActivate:audioSession];
    session.isAudioEnabled = YES;
}

+ (void)audioSessionDidDeactivate:(AVAudioSession *)audioSession
{
    RTCAudioSession *session = [RTCAudioSession sharedInstance];
    [session audioSessionDidDeactivate:audioSession];
    session.isAudioEnabled = NO;
    callAudio = NO;
    [self startKeeping];
}

#pragma mark - state

- (NSDictionary *)stateOf:(CDVPeer *)peer
{
    RTCPeerConnection *pc = peer.pc;
    NSMutableArray *transceivers = [NSMutableArray array];
    NSArray<RTCRtpTransceiver *> *list = pc.transceivers;
    for (NSUInteger i = 0; i < list.count; i++) {
        RTCRtpTransceiver *transceiver = list[i];
        RTCRtpTransceiverDirection current;
        BOOL hasCurrent = [transceiver currentDirection:&current];
        [transceivers addObject:@{
            @"index": @(i),
            @"mid": orNull(transceiver.mid),
            @"kind": transceiver.mediaType == RTCRtpMediaTypeAudio ? @"audio" : @"video",
            @"direction": directionString(transceiver.direction),
            @"currentDirection": hasCurrent ? directionString(current) : [NSNull null],
            @"senderId": orNull(transceiver.sender.senderId),
            @"senderTrackId": orNull(transceiver.sender.track.trackId),
            @"receiverTrackId": orNull(transceiver.receiver.track.trackId),
        }];
    }
    return @{
        @"signalingState": signalingString(pc.signalingState),
        @"iceConnectionState": iceConnectionString(pc.iceConnectionState),
        @"iceGatheringState": gatheringString(pc.iceGatheringState),
        @"connectionState": connectionString(pc.connectionState),
        @"localDescription": descriptionDict(pc.localDescription),
        @"remoteDescription": descriptionDict(pc.remoteDescription),
        @"transceivers": transceivers,
    };
}

- (void)emit:(CDVPeer *)peer event:(NSString *)event extra:(NSDictionary *)extra
{
    CDVCallKeep *plugin = self.plugin;
    if (!plugin || !peer.callbackId || !peer.pc) return;
    NSMutableDictionary *body = [[self stateOf:peer] mutableCopy];
    body[@"event"] = event;
    if (extra) [body addEntriesFromDictionary:extra];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:body];
    [result setKeepCallbackAsBool:YES];
    [plugin.commandDelegate sendPluginResult:result callbackId:peer.callbackId];
}

- (void)watchFrames
{
    if (!self.watches.count) {
        [self.watchTimer invalidate];
        self.watchTimer = nil;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    for (CDVFrameWatch *watch in self.watches.allValues) {
        BOOL live = watch.last > 0 && now - watch.last < 1.0;
        if (live == watch.live) continue;
        watch.live = live;
        CDVPeer *peer = self.peers[watch.pcId];
        if (peer) [self emit:peer event:@"trackmute" extra:@{ @"trackId": watch.trackId, @"muted": @(!live) }];
    }
}

- (void)startWatching
{
    if (self.watchTimer) return;
    self.watchTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(watchFrames) userInfo:nil repeats:YES];
}

#pragma mark - capture

- (void)authorize:(AVMediaType)type then:(void (^)(BOOL granted))done
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
    if (status == AVAuthorizationStatusAuthorized) return done(YES);
    if (status != AVAuthorizationStatusNotDetermined) return done(NO);
    [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(granted); });
    }];
}

- (RTCVideoTrack *)cameraTrack:(NSString *)facing
{
    AVCaptureDevicePosition position = [facing isEqualToString:@"environment"] ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront;
    NSArray<AVCaptureDevice *> *devices = [RTCCameraVideoCapturer captureDevices];
    AVCaptureDevice *device = devices.firstObject;
    for (AVCaptureDevice *candidate in devices) if (candidate.position == position) { device = candidate; break; }
    if (!device) return nil;

    AVCaptureDeviceFormat *format = nil;
    int closest = INT_MAX;
    for (AVCaptureDeviceFormat *candidate in [RTCCameraVideoCapturer supportedFormatsForDevice:device]) {
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription);
        int distance = abs(size.width - 1280) + abs(size.height - 720);
        if (distance < closest) { closest = distance; format = candidate; }
    }
    if (!format) return nil;
    double fastest = 0;
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) fastest = MAX(fastest, range.maxFrameRate);

    RTCVideoSource *source = [self.factory videoSource];
    RTCCameraVideoCapturer *capturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:source];
    // the camera keeps sending while the call is in the system's floating window, where the device allows it
    if (@available(iOS 16.0, *)) {
        AVCaptureSession *session = capturer.captureSession;
        if (session.isMultitaskingCameraAccessSupported) {
            [session beginConfiguration];
            session.multitaskingCameraAccessEnabled = YES;
            [session commitConfiguration];
        }
    }
    RTCVideoTrack *track = [self.factory videoTrackWithSource:source trackId:[NSUUID UUID].UUIDString];
    [capturer startCaptureWithDevice:device format:format fps:(NSInteger)MIN(30.0, fastest) completionHandler:nil];
    self.capturers[track.trackId] = capturer;
    return track;
}

#pragma mark - views

- (RTCMTLVideoView *)viewFor:(NSString *)viewId in:(UIView *)webView
{
    RTCMTLVideoView *view = self.views[viewId];
    if (view) return view;
    view = [[RTCMTLVideoView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [UIColor blackColor];
    view.clipsToBounds = YES;
    view.hidden = YES;
    [webView.superview insertSubview:view belowSubview:webView];
    // the page shows through wherever it draws nothing, and the call's picture is under it
    webView.opaque = NO;
    webView.backgroundColor = [UIColor clearColor];
    if ([webView isKindOfClass:[WKWebView class]]) ((WKWebView *)webView).scrollView.backgroundColor = [UIColor clearColor];
    self.views[viewId] = view;
    return view;
}

- (void)detach:(NSString *)viewId
{
    NSString *trackId = self.viewTracks[viewId];
    RTCMTLVideoView *view = self.views[viewId];
    RTCMediaStreamTrack *track = trackId ? self.tracks[trackId] : nil;
    if (view && [track isKindOfClass:[RTCVideoTrack class]]) [(RTCVideoTrack *)track removeRenderer:view];
    [self.viewTracks removeObjectForKey:viewId];
}

#pragma mark - the system's floating window

// One call's picture at a time goes to the system's floating window: the live call's, whose remote view
// on the page is where the window grows from and goes back to. Armed, it opens by itself when the app
// leaves the foreground; frames go to it only while it is open.
- (void)pipFor:(NSString *)viewId track:(RTCVideoTrack *)track in:(UIView *)webView callback:(NSString *)callbackId
{
    self.pipCallbackId = callbackId;
    if (![self.pipViewId isEqualToString:viewId]) {
        [self pipOff];
        if (![AVPictureInPictureController isPictureInPictureSupported]) return;
        UIView *source = [self viewFor:viewId in:webView];
        self.pipContent = [[AVPictureInPictureVideoCallViewController alloc] init];
        self.pipView = [[CDVSampleView alloc] initWithFrame:self.pipContent.view.bounds];
        self.pipView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.pipContent.view addSubview:self.pipView];
        __weak CDVCallMedia *weakSelf = self;
        self.pipView.sized = ^(CGSize size) { if (size.width > 0 && size.height > 0) weakSelf.pipContent.preferredContentSize = size; };
        AVPictureInPictureControllerContentSource *content =
            [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:source contentViewController:self.pipContent];
        self.pip = [[AVPictureInPictureController alloc] initWithContentSource:content];
        self.pip.delegate = self;
        self.pip.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.pipViewId = viewId;
    }
    if (self.pipTrack == track) return;
    if (self.pipShowing) {
        [self.pipTrack removeRenderer:self.pipView];
        [track addRenderer:self.pipView];
    }
    self.pipTrack = track;
}

- (void)pipOff
{
    self.pip.delegate = nil;
    if (self.pip.isPictureInPictureActive) [self.pip stopPictureInPicture];
    if (self.pipShowing) [self.pipTrack removeRenderer:self.pipView];
    self.pipShowing = NO;
    self.pip = nil;
    self.pipContent = nil;
    self.pipView = nil;
    self.pipTrack = nil;
    self.pipViewId = nil;
}

- (void)pipEmit:(NSString *)event
{
    CDVCallKeep *plugin = self.plugin;
    if (!plugin || !self.pipCallbackId) return;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:event];
    [result setKeepCallbackAsBool:YES];
    [plugin.commandDelegate sendPluginResult:result callbackId:self.pipCallbackId];
}

- (void)pipShow:(BOOL)on
{
    if (on == self.pipShowing) return;
    self.pipShowing = on;
    if (on) [self.pipTrack addRenderer:self.pipView];
    else [self.pipTrack removeRenderer:self.pipView];
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller
{
    CGSize size = self.watches[self.pipTrack.trackId].size;
    self.pipContent.preferredContentSize = size.width > 0 && size.height > 0 ? size : CGSizeMake(16, 9);
    [self pipShow:YES];
    [self pipEmit:@"start"];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error
{
    [self pipShow:NO];
    [self pipEmit:@"stop"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller
{
    [self pipShow:NO];
    [self pipEmit:@"stop"];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL restored))completionHandler
{
    [self pipEmit:@"restore"];
    completionHandler(YES);
}

@end


#pragma mark - commands

@implementation CDVCallKeep (Media)

- (CDVCallMedia *)media
{
    CDVCallMedia *media = [CDVCallMedia shared];
    media.plugin = self;
    return media;
}

- (void)replyState:(CDVPeer *)peer to:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[[self media] stateOf:peer]]
                                callbackId:command.callbackId];
}

- (void)replyError:(NSString *)message to:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Failed"]
                                callbackId:command.callbackId];
}

- (CDVPeer *)peerFor:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self media].peers[stringArg(command.arguments, 0) ?: @""];
    if (!peer) [self replyError:@"InvalidStateError: no such peer connection" to:command];
    return peer;
}

- (void)rtcCreate:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSString *pcId = stringArg(command.arguments, 0);
    if (!pcId) return [self replyError:@"no id" to:command];
    CDVPeer *peer = [[CDVPeer alloc] init];
    peer.pcId = pcId;
    peer.callbackId = command.callbackId;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    peer.pc = [media.factory peerConnectionWithConfiguration:configurationFrom(dictArg(command.arguments, 1) ?: @{}) constraints:constraints delegate:peer];
    if (!peer.pc) return [self replyError:@"could not create a peer connection" to:command];
    media.peers[pcId] = peer;
    [media emit:peer event:@"created" extra:nil];
}

- (void)rtcClose:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSString *pcId = stringArg(command.arguments, 0) ?: @"";
    CDVPeer *peer = media.peers[pcId];
    if (peer) {
        for (RTCRtpTransceiver *transceiver in peer.pc.transceivers) {
            NSString *trackId = transceiver.receiver.track.trackId;
            if (!trackId) continue;
            CDVFrameWatch *watch = media.watches[trackId];
            RTCMediaStreamTrack *track = media.tracks[trackId];
            if (watch && [track isKindOfClass:[RTCVideoTrack class]]) [(RTCVideoTrack *)track removeRenderer:watch];
            [media.watches removeObjectForKey:trackId];
            for (NSString *viewId in [media.viewTracks allKeysForObject:trackId]) {
                [media detach:viewId];
                media.views[viewId].hidden = YES;
            }
            [media.tracks removeObjectForKey:trackId];
        }
        [peer.pc close];
        peer.pc = nil;
        [media.peers removeObjectForKey:pcId];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)rtcSetConfiguration:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    [peer.pc setConfiguration:configurationFrom(dictArg(command.arguments, 1) ?: @{})];
    [self replyState:peer to:command];
}

- (void)describe:(CDVPeer *)peer offer:(BOOL)offer command:(CDVInvokedUrlCommand *)command
{
    NSDictionary *options = dictArg(command.arguments, 1);
    NSDictionary *mandatory = [options[@"iceRestart"] boolValue] ? @{ kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue } : nil;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatory optionalConstraints:nil];
    void (^done)(RTCSessionDescription *, NSError *) = ^(RTCSessionDescription *description, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !description) return [self replyError:error.localizedDescription to:command];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:descriptionDict(description)]
                                        callbackId:command.callbackId];
        });
    };
    if (offer) [peer.pc offerForConstraints:constraints completionHandler:done];
    else [peer.pc answerForConstraints:constraints completionHandler:done];
}

- (void)rtcCreateOffer:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (peer) [self describe:peer offer:YES command:command];
}

- (void)rtcCreateAnswer:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (peer) [self describe:peer offer:NO command:command];
}

- (RTCSessionDescription *)descriptionFrom:(NSDictionary *)description
{
    NSString *type = [description[@"type"] isKindOfClass:[NSString class]] ? description[@"type"] : nil;
    NSString *sdp = [description[@"sdp"] isKindOfClass:[NSString class]] ? description[@"sdp"] : @"";
    if (!type) return nil;
    return [[RTCSessionDescription alloc] initWithType:[RTCSessionDescription typeForString:type] sdp:sdp];
}

- (void)apply:(BOOL)local command:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    RTCSessionDescription *description = [self descriptionFrom:dictArg(command.arguments, 1)];
    void (^done)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) return [self replyError:error.localizedDescription to:command];
            [self replyState:peer to:command];
        });
    };
    if (local && !description) [peer.pc setLocalDescriptionWithCompletionHandler:done];
    else if (!description) [self replyError:@"no description" to:command];
    else if (local) [peer.pc setLocalDescription:description completionHandler:done];
    else [peer.pc setRemoteDescription:description completionHandler:done];
}

- (void)rtcSetLocalDescription:(CDVInvokedUrlCommand *)command { [self apply:YES command:command]; }
- (void)rtcSetRemoteDescription:(CDVInvokedUrlCommand *)command { [self apply:NO command:command]; }

- (void)rtcAddIceCandidate:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    NSDictionary *candidate = dictArg(command.arguments, 1);
    NSString *sdp = [candidate[@"candidate"] isKindOfClass:[NSString class]] ? candidate[@"candidate"] : nil;
    if (!sdp.length) return [self replyState:peer to:command];
    NSString *mid = [candidate[@"sdpMid"] isKindOfClass:[NSString class]] ? candidate[@"sdpMid"] : nil;
    int index = [candidate[@"sdpMLineIndex"] isKindOfClass:[NSNumber class]] ? [candidate[@"sdpMLineIndex"] intValue] : 0;
    [peer.pc addIceCandidate:[[RTCIceCandidate alloc] initWithSdp:sdp sdpMLineIndex:index sdpMid:mid] completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) return [self replyError:error.localizedDescription to:command];
            [self replyState:peer to:command];
        });
    }];
}

- (void)rtcAddTrack:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    RTCMediaStreamTrack *track = [self media].tracks[stringArg(command.arguments, 1) ?: @""];
    if (!track) return [self replyError:@"no such track" to:command];
    id streamIds = command.arguments.count > 2 ? command.arguments[2] : nil;
    if (![streamIds isKindOfClass:[NSArray class]]) streamIds = @[];
    if (![peer.pc addTrack:track streamIds:streamIds]) return [self replyError:@"could not add the track" to:command];
    [self replyState:peer to:command];
}

- (void)rtcAddTransceiver:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    RTCRtpTransceiverInit *init = [[RTCRtpTransceiverInit alloc] init];
    init.direction = directionFrom(stringArg(command.arguments, 2));
    RTCRtpMediaType type = [stringArg(command.arguments, 1) isEqualToString:@"video"] ? RTCRtpMediaTypeVideo : RTCRtpMediaTypeAudio;
    if (![peer.pc addTransceiverOfType:type init:init]) return [self replyError:@"could not add a transceiver" to:command];
    [self replyState:peer to:command];
}

- (void)rtcReplaceTrack:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    NSString *senderId = stringArg(command.arguments, 1);
    NSString *trackId = stringArg(command.arguments, 2);
    for (RTCRtpSender *sender in peer.pc.senders) {
        if (![sender.senderId isEqualToString:senderId]) continue;
        sender.track = trackId ? [self media].tracks[trackId] : nil;
        return [self replyState:peer to:command];
    }
    [self replyError:@"no such sender" to:command];
}

- (void)rtcSetDirection:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    NSInteger index = command.arguments.count > 1 ? [command.arguments[1] integerValue] : -1;
    NSArray<RTCRtpTransceiver *> *transceivers = peer.pc.transceivers;
    if (index < 0 || index >= (NSInteger)transceivers.count) return [self replyError:@"no such transceiver" to:command];
    NSError *error = nil;
    [transceivers[index] setDirection:directionFrom(stringArg(command.arguments, 2)) error:&error];
    if (error) return [self replyError:error.localizedDescription to:command];
    [self replyState:peer to:command];
}

- (void)rtcRestartIce:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    [peer.pc restartIce];
    [self replyState:peer to:command];
}

- (void)rtcGetStats:(CDVInvokedUrlCommand *)command
{
    CDVPeer *peer = [self peerFor:command];
    if (!peer) return;
    [peer.pc statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
        NSMutableArray *entries = [NSMutableArray array];
        for (RTCStatistics *statistics in report.statistics.allValues) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            for (NSString *key in statistics.values) {
                id value = statistics.values[key];
                if ([NSJSONSerialization isValidJSONObject:@[value]]) entry[key] = value;
            }
            entry[@"id"] = statistics.id;
            entry[@"type"] = statistics.type;
            entry[@"timestamp"] = @(statistics.timestamp_us / 1000.0);
            [entries addObject:entry];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:entries]
                                        callbackId:command.callbackId];
        });
    }];
}

- (void)rtcGetUserMedia:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSDictionary *constraints = dictArg(command.arguments, 0) ?: @{};
    BOOL audio = [constraints[@"audio"] boolValue];
    id video = constraints[@"video"];
    BOOL wantsVideo = [video isKindOfClass:[NSString class]] || ([video isKindOfClass:[NSNumber class]] && [video boolValue]);
    NSString *facing = [video isKindOfClass:[NSString class]] ? video : @"user";

    void (^capture)(void) = ^{
        NSMutableArray *tracks = [NSMutableArray array];
        if (audio) {
            RTCMediaConstraints *none = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
            RTCAudioTrack *track = [media.factory audioTrackWithSource:[media.factory audioSourceWithConstraints:none] trackId:[NSUUID UUID].UUIDString];
            media.tracks[track.trackId] = track;
            [tracks addObject:@{ @"id": track.trackId, @"kind": @"audio", @"label": @"microphone" }];
        }
        if (wantsVideo) {
            RTCVideoTrack *track = [media cameraTrack:facing];
            if (!track) return [self replyError:@"NotFoundError: no camera" to:command];
            media.tracks[track.trackId] = track;
            [tracks addObject:@{ @"id": track.trackId, @"kind": @"video", @"label": [facing isEqualToString:@"environment"] ? @"back camera" : @"front camera" }];
        }
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                            messageAsDictionary:@{ @"streamId": [NSUUID UUID].UUIDString, @"tracks": tracks }]
                                    callbackId:command.callbackId];
    };

    void (^askCamera)(void) = ^{
        if (!wantsVideo) return capture();
        [media authorize:AVMediaTypeVideo then:^(BOOL granted) {
            if (!granted) return [self replyError:@"NotAllowedError: camera" to:command];
            capture();
        }];
    };

    if (!audio) return askCamera();
    [media authorize:AVMediaTypeAudio then:^(BOOL granted) {
        if (!granted) return [self replyError:@"NotAllowedError: microphone" to:command];
        askCamera();
    }];
}

- (void)rtcTrackEnabled:(CDVInvokedUrlCommand *)command
{
    RTCMediaStreamTrack *track = [self media].tracks[stringArg(command.arguments, 0) ?: @""];
    track.isEnabled = command.arguments.count > 1 && [command.arguments[1] boolValue];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)rtcTrackStop:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSString *trackId = stringArg(command.arguments, 0) ?: @"";
    RTCCameraVideoCapturer *capturer = media.capturers[trackId];
    if (capturer) [capturer stopCaptureWithCompletionHandler:nil];
    [media.capturers removeObjectForKey:trackId];
    for (NSString *viewId in [media.viewTracks allKeysForObject:trackId]) {
        [media detach:viewId];
        media.views[viewId].hidden = YES;
    }
    media.tracks[trackId].isEnabled = NO;
    [media.tracks removeObjectForKey:trackId];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

// `render(viewId, trackId, rect, options)`: the native picture for one page element, at the element's
// place on the page. No track or no rect hides it; options are `{ mirror, cover, radius }`.
- (void)keepRunning:(CDVInvokedUrlCommand *)command
{
    [CDVCallMedia keepRunning:command.arguments.count > 0 && [command.arguments[0] boolValue]];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)rtcRender:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSString *viewId = stringArg(command.arguments, 0);
    NSString *trackId = stringArg(command.arguments, 1);
    NSDictionary *rect = dictArg(command.arguments, 2);
    NSDictionary *options = dictArg(command.arguments, 3) ?: @{};
    if (!viewId) return [self replyError:@"no view" to:command];

    RTCMediaStreamTrack *track = trackId ? media.tracks[trackId] : nil;
    if (![track isKindOfClass:[RTCVideoTrack class]] || !rect) {
        [media detach:viewId];
        media.views[viewId].hidden = YES;
        return [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    }

    RTCMTLVideoView *view = [media viewFor:viewId in:self.webView];
    if (![media.viewTracks[viewId] isEqualToString:trackId]) {
        [media detach:viewId];
        [(RTCVideoTrack *)track addRenderer:view];
        media.viewTracks[viewId] = trackId;
    }

    CGRect web = self.webView.frame;
    CGFloat width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
    view.transform = CGAffineTransformIdentity;
    view.bounds = CGRectMake(0, 0, width, height);
    view.center = CGPointMake(web.origin.x + [rect[@"x"] doubleValue] + width / 2, web.origin.y + [rect[@"y"] doubleValue] + height / 2);
    if ([options[@"mirror"] boolValue]) view.transform = CGAffineTransformMakeScale(-1, 1);
    view.videoContentMode = [options[@"cover"] boolValue] ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    view.layer.cornerRadius = [options[@"radius"] doubleValue];
    view.hidden = NO;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

// `pip(viewId, trackId)`: the system's floating window for the remote track shown in that view, whose
// callback hears 'start', 'stop' and 'restore'. No track disarms it, if it is still that view's.
- (void)rtcPip:(CDVInvokedUrlCommand *)command
{
    CDVCallMedia *media = [self media];
    NSString *viewId = stringArg(command.arguments, 0);
    RTCMediaStreamTrack *track = media.tracks[stringArg(command.arguments, 1) ?: @""];
    if (viewId && [track isKindOfClass:[RTCVideoTrack class]]) return [media pipFor:viewId track:(RTCVideoTrack *)track in:self.webView callback:command.callbackId];
    if (viewId && [media.pipViewId isEqualToString:viewId]) [media pipOff];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)rtcPipStart:(CDVInvokedUrlCommand *)command
{
    AVPictureInPictureController *pip = [self media].pip;
    BOOL on = command.arguments.count > 0 && [command.arguments[0] boolValue];
    BOOL starting = on && pip.isPictureInPicturePossible && !pip.isPictureInPictureActive;
    if (starting) [pip startPictureInPicture];
    else if (!on && pip.isPictureInPictureActive) [pip stopPictureInPicture];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:starting] callbackId:command.callbackId];
}

@end
