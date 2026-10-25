// The system call UI - CallKit on iOS, ConnectionService on Android - for several calls at once.
//
// The surface is cordova-plugin-callkit's, so an app written for that one keeps working, with what
// several calls need on top: every call has an id, the methods that act on a call take it, and every
// event says which call it is about. A method given no id acts on every call, which is what the
// single-call plugin meant by it.
//
// Events raised before anything listens - an incoming call answered from the lock screen while the
// page is still loading - are kept natively and delivered to the first listener for that event.

var exec = require('cordova/exec');

var SERVICE = 'CordovaCall';
var noop = function () {};

function call(action, args, success, error) {
    exec(success || noop, error || noop, SERVICE, action, args);
}

function flag(name) {
    return function (value, success, error) {
        if (typeof value !== 'boolean') return (error || noop)('Value Must Be True Or False');
        call(name, [value], success, error);
    };
}

// `fn(id, success, error)` and the single-call `fn(success, error)` are both accepted
function onCall(action) {
    return function (id, success, error) {
        if (typeof id === 'function') { error = success; success = id; id = null; }
        call(action, [id == null ? null : String(id)], success, error);
    };
}

exports.setAppName = function (name, success, error) { call('setAppName', [name], success, error); };
exports.setIcon = function (name, success, error) { call('setIcon', [name], success, error); };
exports.setRingtone = function (name, success, error) { call('setRingtone', [name], success, error); };
exports.setIncludeInRecents = flag('setIncludeInRecents');
exports.setDTMFState = flag('setDTMFState');
// what the next receiveCall or sendCall reports, when its options do not say
exports.setVideo = flag('setVideo');
exports.setRingTimeout = function (seconds, success, error) { call('setRingTimeout', [seconds], success, error); };

/**
 * An incoming call. `id` is the app's own id for it; `options` are `{ handle, video }`, the handle
 * being what Recents calls back. Reporting an id the system already has - a VoIP push got there
 * first - binds to that call rather than ringing twice.
 */
exports.receiveCall = function (from, id, options, success, error) {
    if (typeof options === 'function') { error = success; success = options; options = null; }
    if (typeof id === 'function') { error = options; success = id; id = null; options = null; }
    options = options || {};
    call('receiveCall', [from, id == null ? null : String(id), options.handle || null, options.video == null ? null : !!options.video], success, error);
};

/** An outgoing call, same arguments as receiveCall. */
exports.sendCall = function (to, id, options, success, error) {
    if (typeof options === 'function') { error = success; success = options; options = null; }
    if (typeof id === 'function') { error = options; success = id; id = null; options = null; }
    options = options || {};
    call('sendCall', [to, id == null ? null : String(id), options.handle || null, options.video == null ? null : !!options.video], success, error);
};

/** the far end answered an outgoing call */
exports.connectCall = onCall('connectCall');

/** The app ended the call. No `hangup` event follows: that event is for an end the system UI made. */
exports.endCall = onCall('endCall');

/** Put a call on hold or take it off. Taking one off holds whichever call was live. */
exports.setOnHold = function (id, held, success, error) {
    call('setOnHold', [String(id), !!held], success, error);
};

exports.mute = onCall('mute');
exports.unmute = onCall('unmute');
exports.speakerOn = function (success, error) { call('speakerOn', [], success, error); };
exports.speakerOff = function (success, error) { call('speakerOff', [], success, error); };

/**
 * The system's floating window for a call's video - picture in picture. `pip(viewId, track, onevent)`
 * arms it for that view's remote track: it opens by itself when the app leaves the foreground (Android
 * 12 and later), or at once with `showPip(true)`, which resolves to whether it is opening. `onevent`
 * hears 'start', 'stop' and 'restore' - the window's way back to the call. No track disarms it, if it
 * is still that view's.
 *
 * iOS floats the native picture of a CallMedia track, the view being where the window grows from;
 * Android floats the whole app, so the page shows only the call while it is in the window.
 */
exports.pip = function (viewId, track, onevent) {
    call('rtcPip', [viewId, track ? track.id : null], function (event) {
        if (onevent && typeof event === 'string') onevent(event);
    });
};

exports.showPip = function (on) {
    return new Promise(function (resolve) {
        call('rtcPipStart', [!!on], resolve, function () { resolve(false); });
    });
};

/**
 * answer, reject, hangup, hold, unhold, mute, unmute, DTMF - each with `{ callId }`, DTMF also with
 * `digits`; sendCall - a call started from Recents or Siri, with `{ callId, callName, handle,
 * isVideo }`; receiveCall - an incoming call reported, by the app or by a VoIP push, with `{ callId,
 * callName, handle, isVideo }`; speakerOn, speakerOff - the route changed.
 */
exports.on = function (event, fn) {
    call('registerEvent', [event], function (message) { fn(message); });
};
