#import <Cordova/CDV.h>

// The Cordova face of the call manager: `CordovaCall` in config.xml, so that the page's
// `cordova.plugins.CordovaCall` reaches it. Everything with a life longer than one page - CallKit's
// provider, PushKit's registry, the calls - lives in CDVCallKeepCore, which exists from launch.
@interface CDVCallKeep : CDVPlugin

- (void)init:(CDVInvokedUrlCommand *)command;

- (void)setAppName:(CDVInvokedUrlCommand *)command;
- (void)setIcon:(CDVInvokedUrlCommand *)command;
- (void)setRingtone:(CDVInvokedUrlCommand *)command;
- (void)setIncludeInRecents:(CDVInvokedUrlCommand *)command;
- (void)setDTMFState:(CDVInvokedUrlCommand *)command;
- (void)setVideo:(CDVInvokedUrlCommand *)command;
- (void)setRingTimeout:(CDVInvokedUrlCommand *)command;

- (void)receiveCall:(CDVInvokedUrlCommand *)command;
- (void)sendCall:(CDVInvokedUrlCommand *)command;
- (void)connectCall:(CDVInvokedUrlCommand *)command;
- (void)endCall:(CDVInvokedUrlCommand *)command;
- (void)setOnHold:(CDVInvokedUrlCommand *)command;
- (void)mute:(CDVInvokedUrlCommand *)command;
- (void)unmute:(CDVInvokedUrlCommand *)command;
- (void)speakerOn:(CDVInvokedUrlCommand *)command;
- (void)speakerOff:(CDVInvokedUrlCommand *)command;
- (void)registerEvent:(CDVInvokedUrlCommand *)command;

// what the core calls to reach the page
- (BOOL)deliver:(NSString *)event body:(NSDictionary *)body;
- (BOOL)deliverVoIP:(NSDictionary *)body;

@end
