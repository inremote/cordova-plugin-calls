# cordova-plugin-calls

The system call UI for a Cordova app, with several calls at once: CallKit on iOS, Telecom's
ConnectionService (the system dialer) on Android. Calls can be held and resumed from the app or from
the system UI, and a phone call that comes in during an app call holds it, the same as between two
phone calls.

It keeps the JavaScript API of `cordova-plugin-callkit` - `cordova.plugins.CordovaCall` and
`VoIPPushNotification` - so a page written for that plugin runs unchanged. What several calls need is
added on top: every call has an id, the methods that act on a call take it, and every event says which
call it is about. A page can tell the two plugins apart by `typeof CordovaCall.setOnHold === 'function'`.

The two plugins cannot be installed together.

## Install

```xml
<plugin name="cordova-plugin-calls" spec="github:inremote/cordova-plugin-calls#v0.5.6" />
```

Requires cordova-ios 8 and cordova-android 13 or newer. On iOS the app needs the VoIP push entitlement
(the `voip` background mode is added by the plugin) and a VoIP push certificate or key on the server.

## API

```js
const call = cordova.plugins.CordovaCall;

call.setAppName('Acme');                // the name the system UI shows; Android's account label
call.setIcon('logo_transparent');       // iOS: an image in the bundle; Android: a drawable
call.setRingtone('incoming_call');      // iOS: incoming_call.caf in the bundle
call.setIncludeInRecents(true);         // iOS
call.setVideo(false);                   // the default for calls whose options do not say
call.setRingTimeout(45);                // an unanswered incoming call ends after 45 s; 0 (default) never

// `id` is the app's own id for the call; `handle` is what Recents calls back
call.receiveCall('Ann', 'req-123', { handle: 'peer-42', video: false }, ok, fail);
call.sendCall('Bob', 'req-124', { handle: 'peer-43', video: true }, ok, fail);

call.connectCall('req-124');            // the far end answered an outgoing call
call.setOnHold('req-123', true);        // hold, or take off hold
call.mute('req-123'); call.unmute('req-123');
call.speakerOn(); call.speakerOff();
call.endCall('req-123');                // no id: every call

call.pip('remote', track, onevent);     // arm the system's floating window; a null track disarms
call.showPip(true);                     // open it now; resolves to whether it is opening
```

Reporting a call the system already has - a VoIP push got there first - binds to that call rather than
ringing twice. Reporting a call that is already over - declined on the lock screen before the page had
its request - fails with `Call already ended`, and the page should refuse the request.

A video call starts on the speaker and an audio call on the earpiece. On iOS the call's audio session
is a video chat or a voice chat to match, so CallKit's speaker button shows the route the call is on;
`speakerOff` in a video call moves it to a voice chat, the only way off the speaker there.

### Events

`call.on(name, fn)`; every event but the speaker ones carries `{ callId }`.

| Event | When |
|---|---|
| `answer` | answered on the system UI |
| `reject` | declined before it was answered |
| `hangup` | ended on the system UI, refused by the system, or rang past `setRingTimeout` unanswered |
| `hold`, `unhold` | held or resumed on the system UI - by "Hold & Accept", or by a phone call |
| `mute`, `unmute` | muted on the system UI |
| `DTMF` | a key on the system keypad, with `digits` |
| `receiveCall` | an incoming call was reported, by the app or by a VoIP push, with `callName`, `handle`, `isVideo` |
| `sendCall` | a call started from Recents, Contacts or Siri, with `callName`, `handle`, `isVideo` |
| `speakerOn`, `speakerOff` | the audio route moved to or from the speaker, whoever moved it |

Events report what the system UI did. What the app did itself - `endCall`, `setOnHold`, `mute` -
raises nothing. An event raised while nothing listens for it, such as an answer from the lock screen
while the page is still loading, is kept and delivered to the first listener.

### Picture in picture

```js
call.pip('remote', track, (event) => {});   // 'start', 'stop', 'restore'; a null track disarms
const opening = await call.showPip(true);
```

`pip` arms the system's floating window for a call's video - the far end's, or the camera's when there
is none, which iOS and Android stop in the background otherwise. One view is armed at a time, and
arming another while the window is open moves the window to its picture rather than closing it. The
window opens by itself when the app leaves the foreground, or at once with `showPip(true)`; `restore`
is its way back to the call.

- **iOS:** the window shows the native picture of a `CallMedia` track, in the picture's own shape -
  portrait for a phone's camera held upright, following it as it turns. It grows from the view
  `render` draws in and goes back into it drawing the picture as that view does, cropped or fitted.
  The camera keeps sending while it is open where the device supports multitasking camera access. The
  window takes no touches, so it has no buttons of its own.
- **Android:** the whole app is the window (opening by itself from Android 12), so the page shows only
  the call while it is in it; the expand button sends `restore` then `stop`, the X only `stop`.

### VoIP push (iOS)

```js
const push = VoIPPushNotification.init();
push.on('registration', ({ deviceToken }) => { /* send it to the server */ });
push.on('notification', (payload) => {});
```

The plugin registers for VoIP pushes when the app launches, not when the page calls `init()`: iOS
wakes a killed app for a VoIP push and ends it unless the call is reported before the push handler
returns, long before any page has loaded. The plugin reports the call itself and delivers the token and
the pushes to `init()` whenever the page subscribes.

The call is read from the push's `data` field, a JSON string, in cordova-plugin-callkit's format:

```json
{ "data": "{\"Caller\":{\"Username\":\"Ann\",\"ConnectionId\":\"req-123\",\"Handle\":\"peer-42\",\"Video\":false}}" }
```

`ConnectionId` is the call's id, `Username` what the system UI shows. `Handle` (what Recents calls back,
default `ConnectionId`) and `Video` (default `setVideo`) are optional. A push with no call in it is
reported and ended at once, which is what Apple requires.

## Call media (iOS)

CallKit's audio session silences WKWebView's own media: the webview plays and records in WebKit's GPU
process, which a call's session does not reach. `cordova.plugins.CallMedia` runs a call's media in the
app's process instead, on libwebrtc (the `WebRTC-lib` pod), with the session activated by CallKit.

```js
const media = cordova.plugins.CallMedia;

const stream = await media.getUserMedia({ audio: true, video: 'user' });   // or 'environment'
const pc = new media.RTCPeerConnection({ iceServers });                     // the browser's API
stream.getTracks().forEach(track => pc.addTrack(track, stream));

media.render('remote', track, { x, y, width, height }, { cover: true });   // page pixels, or null to hide
media.keepRunning(true);                                                    // counted: every true needs its false
```

`RTCPeerConnection` covers what a call uses - offers and answers, ICE, tracks, transceivers,
`replaceTrack`, `restartIce`, `getStats` - and carries no data channel. Video is not a `srcObject`:
`render` places the native picture under the webview at the given rect, so the page has to be
transparent there; one view per id, so several calls each keep their own, and views that overlap stack
the smaller over the larger, as a picture in picture does. `keepRunning` keeps the app
alive in the background while something other than a call needs it, and steps aside while a call holds
the audio session.

## Platform notes

- **iOS:** up to three call groups of one call each - a live call, a held one and one ringing. Calls
  use a generic handle, so peer ids show as they are. Calling back from Recents arrives through
  cordova-ios 8's scene delegate; a cold launch from Recents is not forwarded by `CDVSceneDelegate`
  and is not handled yet.
- **Android:** the phone account is named after the application's label, renamed by `setAppName`.
  It is a managed one, so calls are the system dialer's to show, hold and
  swap. Android asks the user to switch such an account on once, in the calling accounts settings; the
  plugin opens that screen the first time a call cannot be reported, and the call fails until it is on.
  Placing a call asks for `CALL_PHONE`. An update from `cordova-plugin-callkit` unregisters the phone
  account that plugin left behind.

## Status

Both platforms build in CI. On an iPhone: calls in and out, from the lock screen and in the
foreground, with sound both ways on native media; Recents; hold; the camera switch; the background
keep-alive; picture in picture. Not yet run on a device: two calls at once, Android picture in picture
(0.5.0), the speaker routing (0.5.2), the view stacking (0.5.3), the
window's shape for the camera (0.5.4), its animations matching the view (0.5.5) and one picture
taking over from another (0.5.6).
