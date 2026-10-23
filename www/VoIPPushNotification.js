// VoIP push (PushKit, iOS only), with cordova-plugin-callkit's surface: `VoIPPushNotification.init()`
// returns an emitter of `registration` ({ deviceToken }), `notification` (the push's payload) and
// `error`.
//
// Registration itself does not wait for this. iOS wakes a killed app for a VoIP push and requires
// the call reported before the push handler returns, which is long before any page has loaded - so
// the plugin registers natively at launch and reports the call itself. `init()` only subscribes:
// the token, and any push that came in before, are delivered as soon as it does.

var exec = require('cordova/exec');

function VoIPPushNotification() {
    var that = this;
    this._handlers = { registration: [], notification: [], error: [] };

    // one tick, so that `.on()` calls made right after `init()` are in place for the first event
    setTimeout(function () {
        exec(function (result) {
            if (result && result.registration === 'true') that.emit('registration', result);
            else if (result) that.emit('notification', result);
        }, function (msg) {
            that.emit('error', typeof msg === 'string' ? new Error(msg) : msg);
        }, 'CordovaCall', 'init', []);
    }, 10);
}

VoIPPushNotification.prototype.on = function (event, fn) {
    if (this._handlers[event] && typeof fn === 'function') this._handlers[event].push(fn);
};

VoIPPushNotification.prototype.off = function (event, fn) {
    var list = this._handlers[event];
    if (list && list.indexOf(fn) >= 0) list.splice(list.indexOf(fn), 1);
};

VoIPPushNotification.prototype.emit = function (event) {
    var args = Array.prototype.slice.call(arguments, 1);
    var list = this._handlers[event];
    if (!list) return false;
    list.slice().forEach(function (fn) { fn.apply(undefined, args); });
    return true;
};

module.exports = {
    init: function () { return new VoIPPushNotification(); },
    VoIPPushNotification: VoIPPushNotification
};
