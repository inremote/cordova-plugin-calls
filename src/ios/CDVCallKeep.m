// CallKit and PushKit for several calls at once, each with an id the app chose.
//
// Two objects, because they live for different lengths of time. CDVCallKeepCore is made at launch,
// before any page: iOS wakes a killed app for a VoIP push and ends it unless the call is reported to
// CallKit before the push handler returns, so the registry, the provider and the calls cannot wait
// for a page to ask for them. CDVCallKeep is the plugin a page talks to; it comes and goes with the
// webview, and events raised while no page listens are kept until one does.
//
// Every action the app asks for is remembered by its UUID, and the provider delegate raises no event
// for it: an event says the system UI did something, so the app hears only what it did not do itself.

#import "CDVCallKeep.h"
#import <Cordova/CDVPluginNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>
#import <Intents/Intents.h>
#import <PushKit/PushKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

static NSString *const kSettings = @"CDVCallKeepSettings";

@interface CDVCallKeepCore : NSObject <CXProviderDelegate, PKPushRegistryDelegate>
@property (nonatomic, weak) CDVCallKeep *plugin;
@property (nonatomic, strong) CXProvider *provider;
@property (nonatomic, strong) CXCallController *controller;
@property (nonatomic, strong) PKPushRegistry *registry;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSUUID *> *uuids;   // app id -> CallKit's
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, NSString *> *ids;
@property (nonatomic, strong) NSMutableSet<NSUUID *> *outgoing;
@property (nonatomic, strong) NSMutableSet<NSUUID *> *answered;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *ended;               // ids of calls already over
@property (nonatomic, strong) NSMutableSet<NSUUID *> *own;                        // actions the app asked for
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pending;
@property (nonatomic, strong) NSMutableArray *pendingVoIP;
@property (nonatomic, copy) NSString *voipToken;
@property (nonatomic, strong) NSMutableDictionary *settings;
@property (nonatomic) BOOL speaker;
+ (instancetype)shared;
@end

@implementation CDVCallKeepCore

+ (void)load
{
    // the earliest moment a provider and a registry can be made - and the only one a VoIP push that
    // launched the app leaves time for
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) { [CDVCallKeepCore shared]; }];
}

+ (instancetype)shared
{
    static CDVCallKeepCore *core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ core = [[CDVCallKeepCore alloc] init]; });
    return core;
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _uuids = [NSMutableDictionary dictionary];
    _ids = [NSMutableDictionary dictionary];
    _outgoing = [NSMutableSet set];
    _answered = [NSMutableSet set];
    _ended = [NSMutableOrderedSet orderedSet];
    _own = [NSMutableSet set];
    _pending = [NSMutableDictionary dictionary];
    _pendingVoIP = [NSMutableArray array];
    // what the page set last time, so a call that rings before any page has loaded looks the same
    _settings = [([[NSUserDefaults standardUserDefaults] dictionaryForKey:kSettings] ?: @{}) mutableCopy];

    _provider = [[CXProvider alloc] initWithConfiguration:[self configuration]];
    [_provider setDelegate:self queue:nil];
    _controller = [[CXCallController alloc] init];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeVoiceChat
                                         options:AVAudioSessionCategoryOptionAllowBluetooth error:nil];

    _registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    _registry.delegate = self;
    _registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    // Recents, Contacts and Siri: cordova-ios 8 runs on scenes, and its scene delegate passes the
    // activity on as this notification
    [center addObserver:self selector:@selector(continueActivity:) name:CDVPluginContinueUserActivityNotification object:nil];
    return self;
}

#pragma mark - settings

- (CXProviderConfiguration *)configuration
{
    NSString *name = self.settings[@"appName"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    CXProviderConfiguration *config = [[CXProviderConfiguration alloc] initWithLocalizedName:name ?: @""];
    // one call per group, and room for a held call next to the live one and one more ringing
    config.maximumCallGroups = 3;
    config.maximumCallsPerCallGroup = 1;
    config.supportsVideo = YES;
    config.supportedHandleTypes = [NSSet setWithObjects:@(CXHandleTypeGeneric), @(CXHandleTypePhoneNumber), nil];
    config.includesCallsInRecents = [self.settings[@"includeInRecents"] boolValue];
    if (self.settings[@"ringtone"]) config.ringtoneSound = self.settings[@"ringtone"];
    UIImage *icon = self.settings[@"icon"] ? [UIImage imageNamed:self.settings[@"icon"]] : nil;
    if (icon) config.iconTemplateImageData = UIImagePNGRepresentation(icon);
    return config;
}

- (void)set:(NSString *)key value:(id)value
{
    self.settings[key] = value;
    [[NSUserDefaults standardUserDefaults] setObject:self.settings forKey:kSettings];
    self.provider.configuration = [self configuration];
}

#pragma mark - events

- (void)emit:(NSString *)event body:(NSDictionary *)body
{
    if ([self.plugin deliver:event body:body]) return;
    if (!self.pending[event]) self.pending[event] = [NSMutableArray array];
    [self.pending[event] addObject:body];
}

- (NSArray *)takePending:(NSString *)event
{
    NSArray *list = self.pending[event] ?: @[];
    [self.pending removeObjectForKey:event];
    return list;
}

- (void)emitVoIP:(NSDictionary *)body
{
    if (![self.plugin deliverVoIP:body]) [self.pendingVoIP addObject:body];
}

- (NSDictionary *)describe:(NSUUID *)uuid extra:(NSDictionary *)extra
{
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:self.ids[uuid] ?: uuid.UUIDString forKey:@"callId"];
    if (extra) [body addEntriesFromDictionary:extra];
    return body;
}

#pragma mark - calls

- (NSUUID *)uuidFor:(NSString *)callId create:(BOOL)create
{
    NSUUID *uuid = self.uuids[callId];
    if (uuid || !create) return uuid;
    uuid = [NSUUID UUID];
    self.uuids[callId] = uuid;
    self.ids[uuid] = callId;
    return uuid;
}

// A call that is over stays over: declined on the lock screen before the page had its request, it is
// not rung again when the request arrives. Request ids are never reused, and a few dozen is plenty.
- (void)forget:(NSUUID *)uuid
{
    NSString *callId = self.ids[uuid];
    if (callId) {
        [self.uuids removeObjectForKey:callId];
        [self.ended addObject:callId];
        if (self.ended.count > 50) [self.ended removeObjectAtIndex:0];
    }
    [self.ids removeObjectForKey:uuid];
    [self.outgoing removeObject:uuid];
    [self.answered removeObject:uuid];
}

- (CXCallUpdate *)updateFor:(NSString *)name handle:(NSString *)handle video:(BOOL)video
{
    CXCallUpdate *update = [[CXCallUpdate alloc] init];
    update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle];
    update.localizedCallerName = name;
    update.hasVideo = video;
    update.supportsHolding = YES;
    update.supportsGrouping = NO;
    update.supportsUngrouping = NO;
    update.supportsDTMF = [self.settings[@"dtmf"] boolValue];
    return update;
}

- (void)reportIncoming:(NSString *)callId name:(NSString *)name handle:(NSString *)handle video:(BOOL)video
            completion:(void (^)(NSError *error))completion
{
    if ([self.ended containsObject:callId]) {
        if (completion) completion([NSError errorWithDomain:@"CallKeep" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Call already ended" }]);
        return;
    }
    BOOL known = self.uuids[callId] != nil;
    NSUUID *uuid = [self uuidFor:callId create:YES];
    [self.provider reportNewIncomingCallWithUUID:uuid update:[self updateFor:name handle:handle video:video]
        completion:^(NSError *reported) { dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = reported;
            // the same call reported twice - a VoIP push and the page both got there - is one call
            if (error && error.code == CXErrorCodeIncomingCallErrorCallUUIDAlreadyExists) error = nil;
            if (error && !known) [self forget:uuid];
            if (!error && !known) {
                [self emit:@"receiveCall" body:[self describe:uuid extra:@{ @"callName": name ?: @"", @"handle": handle ?: @"", @"isVideo": @(video) }]];
                [self expireIfUnanswered:uuid];
            }
            if (completion) completion(error);
        }); }];
}

- (void)expireIfUnanswered:(NSUUID *)uuid
{
    int64_t seconds = [self.settings[@"ringTimeout"] longLongValue];
    if (seconds <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.ids[uuid] || [self.answered containsObject:uuid]) return;
        NSDictionary *body = [self describe:uuid extra:nil];
        [self.provider reportCallWithUUID:uuid endedAtDate:nil reason:CXCallEndedReasonUnanswered];
        [self forget:uuid];
        [self emit:@"hangup" body:body];
    });
}

- (void)request:(CXAction *)action completion:(void (^)(NSError *error))completion
{
    [self.own addObject:action.UUID];
    // CallKit answers on a queue of its own; everything here is touched on the main one
    [self.controller requestTransaction:[[CXTransaction alloc] initWithAction:action] completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) [self.own removeObject:action.UUID];
            if (completion) completion(error);
        });
    }];
}

// whether the app asked for this action itself, which raises no event
- (BOOL)isOwn:(CXAction *)action
{
    if (![self.own containsObject:action.UUID]) return NO;
    [self.own removeObject:action.UUID];
    return YES;
}

#pragma mark - CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider
{
    // every call is gone: the app hears a hangup for each, so nothing is left believing it is on one
    for (NSUUID *uuid in [self.ids allKeys]) [self emit:@"hangup" body:[self describe:uuid extra:nil]];
    [self.uuids removeAllObjects];
    [self.ids removeAllObjects];
    [self.outgoing removeAllObjects];
    [self.answered removeAllObjects];
    [self.own removeAllObjects];
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action
{
    [self.outgoing addObject:action.callUUID];
    [provider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:nil];
    CXCallUpdate *update = [self updateFor:action.contactIdentifier handle:action.handle.value video:action.video];
    [provider reportCallWithUUID:action.callUUID updated:update];
    [action fulfill];

    // a call the app placed already knows itself; one placed from Recents or Siri is news
    if ([self isOwn:action]) return;
    if (!self.ids[action.callUUID]) {
        self.ids[action.callUUID] = action.callUUID.UUIDString;
        self.uuids[action.callUUID.UUIDString] = action.callUUID;
    }
    [self emit:@"sendCall" body:[self describe:action.callUUID extra:@{
        @"callName": action.contactIdentifier ?: @"", @"handle": action.handle.value ?: @"", @"isVideo": @(action.video) }]];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action
{
    [self.answered addObject:action.callUUID];
    [action fulfill];
    [self emit:@"answer" body:[self describe:action.callUUID extra:nil]];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action
{
    NSUUID *uuid = action.callUUID;
    BOOL connected = NO;
    for (CXCall *call in self.controller.callObserver.calls) if ([call.UUID isEqual:uuid]) connected = call.hasConnected;
    NSDictionary *body = [self describe:uuid extra:nil];
    BOOL own = [self isOwn:action];
    [action fulfill];
    [self forget:uuid];
    // declining a call that never connected is a reject; anything else is a hangup
    if (!own) [self emit:(connected || [self.outgoing containsObject:uuid] ? @"hangup" : @"reject") body:body];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action
{
    [action fulfill];
    if (![self isOwn:action]) [self emit:(action.onHold ? @"hold" : @"unhold") body:[self describe:action.callUUID extra:nil]];
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action
{
    [action fulfill];
    if (![self isOwn:action]) [self emit:(action.muted ? @"mute" : @"unmute") body:[self describe:action.callUUID extra:nil]];
}

- (void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action
{
    [action fulfill];
    [self emit:@"DTMF" body:[self describe:action.callUUID extra:@{ @"digits": action.digits ?: @"" }]];
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession
{
    self.speaker = [self onSpeaker];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {}

#pragma mark - audio route

- (BOOL)onSpeaker
{
    for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return YES;
    }
    return NO;
}

// told only when the speaker actually came or went, during a call, whoever moved it
- (void)routeChanged:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.ids.count) return;
        BOOL speaker = [self onSpeaker];
        if (speaker == self.speaker) return;
        self.speaker = speaker;
        [self emit:(speaker ? @"speakerOn" : @"speakerOff") body:@{}];
    });
}

#pragma mark - Recents, Contacts, Siri

- (void)continueActivity:(NSNotification *)note
{
    NSUserActivity *activity = note.object;
    INIntent *intent = activity.interaction.intent;
    INPerson *person = nil;
    BOOL video = NO;
    if ([intent isKindOfClass:[INStartCallIntent class]]) {
        INStartCallIntent *start = (INStartCallIntent *)intent;
        person = start.contacts.firstObject;
        video = start.callCapability == INCallCapabilityVideoCall;
    }
    NSString *handle = person.personHandle.value;
    if (!handle.length) return;
    NSString *name = person.displayName.length ? person.displayName : handle;
    CXStartCallAction *start = [[CXStartCallAction alloc] initWithCallUUID:[NSUUID UUID]
                                                                    handle:[[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle]];
    start.contactIdentifier = name;
    start.video = video;
    // not the app's own: performStartCallAction tells the page, which places the call
    [self.controller requestTransaction:[[CXTransaction alloc] initWithAction:start] completion:^(NSError *error) {
        if (error) NSLog(@"[CallKeep] could not start a call from Recents: %@", error);
    }];
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type
{
    const unsigned char *bytes = credentials.token.bytes;
    NSMutableString *token = [NSMutableString stringWithCapacity:credentials.token.length * 2];
    for (NSUInteger i = 0; i < credentials.token.length; i++) [token appendFormat:@"%02x", bytes[i]];
    if (!token.length) return;
    self.voipToken = token;
    [self emitVoIP:@{ @"registration": @"true", @"deviceToken": token }];
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type
{
    self.voipToken = nil;
}

// Reported here and now, whatever the page is doing: iOS ends an app that receives a VoIP push and
// does not report a call before the completion handler runs, and stops delivering them after a few.
// A push that carries no call is reported and ended at once, which is what Apple asks for.
- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type withCompletionHandler:(void (^)(void))completion
{
    NSDictionary *push = payload.dictionaryPayload;
    NSDictionary *caller = nil;
    if ([push[@"data"] isKindOfClass:[NSString class]]) {
        id json = [NSJSONSerialization JSONObjectWithData:[push[@"data"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"Caller"] isKindOfClass:[NSDictionary class]]) caller = json[@"Caller"];
    }

    id rawId = caller[@"ConnectionId"];
    NSString *callId = rawId ? [NSString stringWithFormat:@"%@", rawId] : nil;
    NSString *name = [caller[@"Username"] isKindOfClass:[NSString class]] ? caller[@"Username"] : @"Unknown Caller";
    NSString *handle = caller[@"Handle"] ? [NSString stringWithFormat:@"%@", caller[@"Handle"]] : callId;
    BOOL video = caller[@"Video"] ? [caller[@"Video"] boolValue] : [self.settings[@"video"] boolValue];

    [self emitVoIP:push];

    // nothing to ring for - no call in it, or one already over - and still a call must be reported
    if (!callId || [self.ended containsObject:callId]) {
        NSUUID *uuid = [NSUUID UUID];
        [self.provider reportNewIncomingCallWithUUID:uuid update:[self updateFor:name handle:@"" video:NO] completion:^(NSError *error) {
            [self.provider reportCallWithUUID:uuid endedAtDate:nil reason:CXCallEndedReasonFailed];
            completion();
        }];
        return;
    }

    [self reportIncoming:callId name:name handle:handle video:video completion:^(NSError *error) {
        if (error) NSLog(@"[CallKeep] incoming call not reported: %@", error);
        completion();
    }];
}

@end


#pragma mark - the plugin

@implementation CDVCallKeep
{
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_listeners;
    NSString *_voipCallback;
}

- (void)pluginInitialize
{
    _listeners = [NSMutableDictionary dictionary];
    [CDVCallKeepCore shared].plugin = self;
    if ([self.webView isKindOfClass:[WKWebView class]]) {
        WKPreferences *preferences = ((WKWebView *)self.webView).configuration.preferences;
        [self disableWebKitFeature:@"CaptureAudioInGPUProcessEnabled" in:preferences];
        [self disableWebKitFeature:@"UseGPUProcessForMediaEnabled" in:preferences];
    }
}

- (void)disableWebKitFeature:(NSString *)key in:(WKPreferences *)preferences
{
    SEL list = NSSelectorFromString(@"_features");
    SEL set = NSSelectorFromString(@"_setEnabled:forFeature:");
    if (![WKPreferences respondsToSelector:list] || ![preferences respondsToSelector:set]) {
        NSLog(@"[CallKeep] WebKit offers no feature switches; %@ left as it is", key);
        return;
    }
    NSArray *features = ((NSArray *(*)(id, SEL))objc_msgSend)([WKPreferences class], list);
    for (id feature in features) {
        if (![[feature valueForKey:@"key"] isEqual:key]) continue;
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, set, NO, feature);
        NSLog(@"[CallKeep] %@ off", key);
        return;
    }
    NSLog(@"[CallKeep] WebKit has no feature %@", key);
}

// a new page: the callbacks belonged to the one that went
- (void)onReset
{
    [_listeners removeAllObjects];
    _voipCallback = nil;
}

#pragma mark - delivery

- (void)send:(NSDictionary *)body to:(NSString *)callbackId
{
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:body];
    [result setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (BOOL)deliver:(NSString *)event body:(NSDictionary *)body
{
    NSArray *list = _listeners[event];
    if (!list.count) return NO;
    for (NSString *callbackId in list) [self send:body to:callbackId];
    return YES;
}

- (BOOL)deliverVoIP:(NSDictionary *)body
{
    if (!_voipCallback) return NO;
    [self send:body to:_voipCallback];
    return YES;
}

- (void)ok:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)fail:(CDVInvokedUrlCommand *)command message:(NSString *)message
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message] callbackId:command.callbackId];
}

- (void)finish:(CDVInvokedUrlCommand *)command error:(NSError *)error
{
    if (error) [self fail:command message:error.localizedDescription];
    else [self ok:command];
}

- (id)arg:(CDVInvokedUrlCommand *)command at:(NSUInteger)index
{
    id value = index < command.arguments.count ? command.arguments[index] : nil;
    return value == [NSNull null] ? nil : value;
}

// the calls a command is about: the one it names, or every call when it names none
- (NSArray<NSUUID *> *)targets:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    NSString *callId = [self arg:command at:0];
    if (!callId) return [core.ids allKeys];
    NSUUID *uuid = [core uuidFor:callId create:NO];
    return uuid ? @[uuid] : @[];
}

#pragma mark - commands

- (void)init:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    _voipCallback = command.callbackId;
    if (core.voipToken) [self send:@{ @"registration": @"true", @"deviceToken": core.voipToken } to:_voipCallback];
    for (NSDictionary *push in core.pendingVoIP) [self send:push to:_voipCallback];
    [core.pendingVoIP removeAllObjects];
}

- (void)registerEvent:(CDVInvokedUrlCommand *)command
{
    NSString *event = [self arg:command at:0];
    if (!event) return;
    if (!_listeners[event]) _listeners[event] = [NSMutableArray array];
    [_listeners[event] addObject:command.callbackId];
    for (NSDictionary *body in [[CDVCallKeepCore shared] takePending:event]) [self send:body to:command.callbackId];
}

- (void)setAppName:(CDVInvokedUrlCommand *)command
{
    NSString *name = [self arg:command at:0];
    if (!name.length) return [self fail:command message:@"App Name Can't Be Empty"];
    [[CDVCallKeepCore shared] set:@"appName" value:name];
    [self ok:command];
}

- (void)setIcon:(CDVInvokedUrlCommand *)command
{
    NSString *name = [self arg:command at:0];
    if (!name.length || ![UIImage imageNamed:name]) return [self fail:command message:@"This icon does not exist"];
    [[CDVCallKeepCore shared] set:@"icon" value:name];
    [self ok:command];
}

- (void)setRingtone:(CDVInvokedUrlCommand *)command
{
    NSString *name = [self arg:command at:0];
    if (!name.length) return [self fail:command message:@"Ringtone Name Can't Be Empty"];
    [[CDVCallKeepCore shared] set:@"ringtone" value:[name stringByAppendingString:@".caf"]];
    [self ok:command];
}

- (void)setIncludeInRecents:(CDVInvokedUrlCommand *)command
{
    [[CDVCallKeepCore shared] set:@"includeInRecents" value:@([[self arg:command at:0] boolValue])];
    [self ok:command];
}

- (void)setDTMFState:(CDVInvokedUrlCommand *)command
{
    [[CDVCallKeepCore shared] set:@"dtmf" value:@([[self arg:command at:0] boolValue])];
    [self ok:command];
}

- (void)setVideo:(CDVInvokedUrlCommand *)command
{
    [[CDVCallKeepCore shared] set:@"video" value:@([[self arg:command at:0] boolValue])];
    [self ok:command];
}

- (void)setRingTimeout:(CDVInvokedUrlCommand *)command
{
    [[CDVCallKeepCore shared] set:@"ringTimeout" value:@([[self arg:command at:0] longLongValue])];
    [self ok:command];
}

- (BOOL)videoFrom:(CDVInvokedUrlCommand *)command
{
    id video = [self arg:command at:3];
    return video ? [video boolValue] : [[CDVCallKeepCore shared].settings[@"video"] boolValue];
}

- (void)receiveCall:(CDVInvokedUrlCommand *)command
{
    NSString *name = [self arg:command at:0];
    if (!name.length) return [self fail:command message:@"Caller id can't be empty"];
    NSString *callId = [self arg:command at:1] ?: [NSUUID UUID].UUIDString;
    NSString *handle = [self arg:command at:2] ?: callId;
    [[CDVCallKeepCore shared] reportIncoming:callId name:name handle:handle video:[self videoFrom:command]
        completion:^(NSError *error) { [self finish:command error:error]; }];
}

- (void)sendCall:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    NSString *name = [self arg:command at:0];
    if (!name.length) return [self fail:command message:@"The caller id can't be empty"];
    NSString *callId = [self arg:command at:1] ?: [NSUUID UUID].UUIDString;
    NSString *handle = [self arg:command at:2] ?: callId;
    if ([core uuidFor:callId create:NO]) return [self ok:command];

    NSUUID *uuid = [core uuidFor:callId create:YES];
    CXStartCallAction *start = [[CXStartCallAction alloc] initWithCallUUID:uuid
                                                                    handle:[[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle]];
    start.contactIdentifier = name;
    start.video = [self videoFrom:command];
    [core request:start completion:^(NSError *error) {
        if (error) [core forget:uuid];
        [self finish:command error:error];
    }];
}

- (void)connectCall:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    for (NSUUID *uuid in [self targets:command]) {
        if ([core.outgoing containsObject:uuid]) [core.provider reportOutgoingCallWithUUID:uuid connectedAtDate:nil];
    }
    [self ok:command];
}

- (void)endCall:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    for (NSUUID *uuid in [self targets:command]) {
        [core request:[[CXEndCallAction alloc] initWithCallUUID:uuid] completion:^(NSError *error) {
            // CallKit no longer has it: told directly, and forgotten either way
            if (error) [core.provider reportCallWithUUID:uuid endedAtDate:nil reason:CXCallEndedReasonRemoteEnded];
            [core forget:uuid];
        }];
    }
    [self ok:command];
}

- (void)setOnHold:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    NSUUID *uuid = [core uuidFor:[self arg:command at:0] create:NO];
    if (!uuid) return [self fail:command message:@"No such call"];
    [core request:[[CXSetHeldCallAction alloc] initWithCallUUID:uuid onHold:[[self arg:command at:1] boolValue]]
       completion:^(NSError *error) { [self finish:command error:error]; }];
}

- (void)setMuted:(BOOL)muted command:(CDVInvokedUrlCommand *)command
{
    CDVCallKeepCore *core = [CDVCallKeepCore shared];
    for (NSUUID *uuid in [self targets:command]) [core request:[[CXSetMutedCallAction alloc] initWithCallUUID:uuid muted:muted] completion:nil];
    [self ok:command];
}

- (void)mute:(CDVInvokedUrlCommand *)command { [self setMuted:YES command:command]; }
- (void)unmute:(CDVInvokedUrlCommand *)command { [self setMuted:NO command:command]; }

- (void)setSpeaker:(BOOL)on command:(CDVInvokedUrlCommand *)command
{
    NSError *error = nil;
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:(on ? AVAudioSessionPortOverrideSpeaker : AVAudioSessionPortOverrideNone) error:&error];
    [self finish:command error:error];
}

- (void)speakerOn:(CDVInvokedUrlCommand *)command { [self setSpeaker:YES command:command]; }
- (void)speakerOff:(CDVInvokedUrlCommand *)command { [self setSpeaker:NO command:command]; }

@end
