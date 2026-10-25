// A call's media in the app's own process (iOS): the browser's RTCPeerConnection, MediaStream and
// getUserMedia, as far as a call uses them, over libwebrtc in the plugin. A page hands this
// RTCPeerConnection to its WebRTC code for a call and leaves everything else on the webview's own.
//
// Video is not a srcObject: render(viewId, track, rect) puts the native picture under the webview at
// the element's place, and the page has to be transparent there.

var exec = require('cordova/exec');

function failure(message) {
    var text = String(message || 'Failed');
    var error = new Error(text);
    var name = text.split(':')[0];
    if (/Error$/.test(name)) error.name = name;
    return error;
}

function call(action, args) {
    return new Promise(function (resolve, reject) {
        exec(resolve, function (message) { reject(failure(message)); }, 'CordovaCall', action, args || []);
    });
}

var counter = 0;
function uid(prefix) { return prefix + Date.now().toString(36) + (counter++).toString(36); }

function Target() { this._listeners = {}; }
Target.prototype.addEventListener = function (type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); };
Target.prototype.removeEventListener = function (type, fn) {
    var list = this._listeners[type] || [];
    if (list.indexOf(fn) >= 0) list.splice(list.indexOf(fn), 1);
};
Target.prototype._fire = function (type, event) {
    event = event || {};
    event.type = type;
    event.target = this;
    var handler = this['on' + type];
    if (typeof handler === 'function') handler.call(this, event);
    (this._listeners[type] || []).slice().forEach(function (fn) { fn.call(this, event); }, this);
};

var tracks = {};

function MediaStreamTrack(id, kind, label, remote) {
    Target.call(this);
    this.id = id;
    this.kind = kind;
    this.label = label || '';
    this.remote = !!remote;
    // a received picture is there only once frames arrive; the plugin says when they do and stop
    this.muted = !!remote && kind === 'video';
    this.readyState = 'live';
    this._enabled = true;
    tracks[id] = this;
}
MediaStreamTrack.prototype = Object.create(Target.prototype);
Object.defineProperty(MediaStreamTrack.prototype, 'enabled', {
    get: function () { return this._enabled; },
    set: function (on) {
        on = !!on;
        if (on === this._enabled) return;
        this._enabled = on;
        call('rtcTrackEnabled', [this.id, on]);
    },
});
MediaStreamTrack.prototype.stop = function () {
    if (this.readyState === 'ended') return;
    this.readyState = 'ended';
    delete tracks[this.id];
    call('rtcTrackStop', [this.id]);
};
MediaStreamTrack.prototype.getSettings = function () { return {}; };

function remoteTrack(id, kind) {
    return tracks[id] || new MediaStreamTrack(id, kind, '', true);
}

function MediaStream(list, id) {
    this.id = id || uid('ms');
    this._tracks = (list || []).slice();
}
MediaStream.prototype.getTracks = function () { return this._tracks.slice(); };
MediaStream.prototype.getAudioTracks = function () { return this._tracks.filter(function (t) { return t.kind === 'audio'; }); };
MediaStream.prototype.getVideoTracks = function () { return this._tracks.filter(function (t) { return t.kind === 'video'; }); };
MediaStream.prototype.addTrack = function (track) { if (this._tracks.indexOf(track) < 0) this._tracks.push(track); };
MediaStream.prototype.removeTrack = function (track) {
    var at = this._tracks.indexOf(track);
    if (at >= 0) this._tracks.splice(at, 1);
};

function RTCRtpSender(pc, id) {
    this._pc = pc;
    this.id = id;
    this.track = null;
}
RTCRtpSender.prototype.replaceTrack = function (track) {
    this.track = track || null;
    return this._pc._op('rtcReplaceTrack', [this.id, track ? track.id : null]).then(function () {});
};

function RTCRtpTransceiver(pc, index) {
    this._pc = pc;
    this._index = index;
    this.sender = null;
    this.receiver = { track: null };
    this.mid = null;
    this.currentDirection = null;
    this._direction = 'sendrecv';
}
Object.defineProperty(RTCRtpTransceiver.prototype, 'direction', {
    get: function () { return this._direction; },
    set: function (direction) {
        if (direction === this._direction) return;
        this._direction = direction;
        this._pc._op('rtcSetDirection', [this._index, direction]);
    },
});
RTCRtpTransceiver.prototype._update = function (state) {
    this.mid = state.mid || null;
    this.kind = state.kind;
    this._direction = state.direction;
    this.currentDirection = state.currentDirection || null;
    if (state.senderId && (!this.sender || this.sender.id !== state.senderId)) this.sender = new RTCRtpSender(this._pc, state.senderId);
    if (this.sender) this.sender.track = state.senderTrackId ? tracks[state.senderTrackId] || this.sender.track : null;
    this.receiver.track = state.receiverTrackId ? remoteTrack(state.receiverTrackId, state.kind) : null;
};

function RTCPeerConnection(config) {
    Target.call(this);
    var pc = this;
    this._id = uid('pc');
    this._transceivers = [];
    this._streams = {};
    this.signalingState = 'stable';
    this.iceConnectionState = 'new';
    this.iceGatheringState = 'new';
    this.connectionState = 'new';
    this.localDescription = null;
    this.remoteDescription = null;
    this._chain = new Promise(function (resolve, reject) {
        exec(function (message) {
            if (message.event === 'created') {
                pc._sync(message);
                resolve();
                return;
            }
            pc._event(message);
        }, function (message) { reject(failure(message)); }, 'CordovaCall', 'rtcCreate', [pc._id, config || {}]);
    });
}
RTCPeerConnection.prototype = Object.create(Target.prototype);

// one native call at a time, in the order they were asked for, as a browser's operations chain does
RTCPeerConnection.prototype._op = function (action, args) {
    var pc = this;
    var result = this._chain.then(function () {
        return call(action, [pc._id].concat(args || []));
    }).then(function (state) {
        if (state && state.transceivers) pc._sync(state);
        return state;
    });
    this._chain = result.catch(function () {});
    return result;
};

RTCPeerConnection.prototype._sync = function (state) {
    var pc = this;
    this.signalingState = state.signalingState;
    this.iceConnectionState = state.iceConnectionState;
    this.iceGatheringState = state.iceGatheringState;
    this.connectionState = state.connectionState;
    this.localDescription = state.localDescription || null;
    this.remoteDescription = state.remoteDescription || null;
    (state.transceivers || []).forEach(function (t) {
        var transceiver = pc._transceivers[t.index] || (pc._transceivers[t.index] = new RTCRtpTransceiver(pc, t.index));
        transceiver._update(t);
    });
};

RTCPeerConnection.prototype._event = function (message) {
    if (this.signalingState === 'closed') return;
    this._sync(message);
    switch (message.event) {
        case 'icecandidate':
            return this._fire('icecandidate', { candidate: message.candidate || null });
        case 'track': {
            var track = remoteTrack(message.trackId, message.kind);
            var pc = this;
            var streams = (message.streamIds || []).map(function (id) {
                var stream = pc._streams[id] || (pc._streams[id] = new MediaStream([], id));
                stream.addTrack(track);
                return stream;
            });
            if (!streams.length) streams.push(new MediaStream([track]));
            return this._fire('track', { track: track, streams: streams, transceiver: this._transceivers[message.transceiver] || null });
        }
        case 'trackmute': {
            var muted = tracks[message.trackId];
            if (!muted || muted.muted === !!message.muted) return;
            muted.muted = !!message.muted;
            return muted._fire(muted.muted ? 'mute' : 'unmute');
        }
        default:
            return this._fire(message.event);
    }
};

RTCPeerConnection.prototype.createOffer = function (options) {
    return this._op('rtcCreateOffer', [{ iceRestart: !!(options && options.iceRestart) }]);
};
RTCPeerConnection.prototype.createAnswer = function () { return this._op('rtcCreateAnswer'); };
RTCPeerConnection.prototype.setLocalDescription = function (description) {
    return this._op('rtcSetLocalDescription', [description ? { type: description.type, sdp: description.sdp } : null]).then(function () {});
};
RTCPeerConnection.prototype.setRemoteDescription = function (description) {
    return this._op('rtcSetRemoteDescription', [{ type: description.type, sdp: description.sdp }]).then(function () {});
};
RTCPeerConnection.prototype.addIceCandidate = function (candidate) {
    var plain = candidate ? { candidate: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex } : null;
    return this._op('rtcAddIceCandidate', [plain]).then(function () {});
};
RTCPeerConnection.prototype.addTrack = function (track) {
    var streams = Array.prototype.slice.call(arguments, 1).filter(Boolean).map(function (s) { return s.id; });
    this._op('rtcAddTrack', [track.id, streams]);
};
RTCPeerConnection.prototype.addTransceiver = function (kind, init) {
    this._op('rtcAddTransceiver', [kind, (init && init.direction) || 'sendrecv']);
};
RTCPeerConnection.prototype.getTransceivers = function () { return this._transceivers.slice(); };
RTCPeerConnection.prototype.getSenders = function () {
    return this._transceivers.map(function (t) { return t.sender; }).filter(Boolean);
};
RTCPeerConnection.prototype.getReceivers = function () {
    return this._transceivers.map(function (t) { return t.receiver; });
};
RTCPeerConnection.prototype.restartIce = function () { this._op('rtcRestartIce'); };
RTCPeerConnection.prototype.setConfiguration = function (config) { this._op('rtcSetConfiguration', [config || {}]); };
RTCPeerConnection.prototype.getStats = function () {
    var pc = this;
    return this._chain.then(function () { return call('rtcGetStats', [pc._id]); }).then(function (entries) {
        var report = new Map();
        (entries || []).forEach(function (entry) { report.set(entry.id, entry); });
        return report;
    });
};
RTCPeerConnection.prototype.createDataChannel = function () {
    throw failure('NotSupportedError: a call carries no data channel');
};
RTCPeerConnection.prototype.close = function () {
    if (this.signalingState === 'closed') return;
    this.signalingState = 'closed';
    this.connectionState = 'closed';
    this.iceConnectionState = 'closed';
    var pc = this;
    this._chain.then(function () { return call('rtcClose', [pc._id]); });
};

// `{ audio, video }`, video being true, 'user', 'environment' or `{ facingMode }` as a browser takes it
function getUserMedia(constraints) {
    constraints = constraints || {};
    var video = constraints.video;
    if (video && typeof video === 'object') {
        var facing = video.facingMode;
        video = (facing && (facing.exact || facing.ideal)) || facing || 'user';
    }
    if (video === true) video = 'user';
    return call('rtcGetUserMedia', [{ audio: !!constraints.audio, video: video || false }]).then(function (result) {
        var list = result.tracks.map(function (t) { return new MediaStreamTrack(t.id, t.kind, t.label, false); });
        return new MediaStream(list, result.streamId);
    });
}

// the native picture for one page element: a track and a rect in page pixels, or none to hide it
function render(viewId, track, rect, options) {
    return call('rtcRender', [viewId, track ? track.id : null, rect || null, options || {}]);
}

// keep the app running while a remote session is live; counted, so every true needs its false
function keepRunning(on) {
    return call('keepRunning', [!!on]);
}

module.exports = {
    RTCPeerConnection: RTCPeerConnection,
    MediaStream: MediaStream,
    getUserMedia: getUserMedia,
    render: render,
    keepRunning: keepRunning,
};
