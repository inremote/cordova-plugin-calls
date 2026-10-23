package com.inremote.calls;

import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.telecom.CallAudioState;
import android.telecom.Connection;
import android.telecom.DisconnectCause;
import android.telecom.StatusHints;
import android.telecom.TelecomManager;
import android.telecom.VideoProfile;

import org.json.JSONException;
import org.json.JSONObject;

// One call, as Telecom sees it. What the system UI does to it - answer, decline, hold, hang up, mute,
// change the route - becomes an event for the page; what the app does to it is done here and raises
// nothing, since the app already knows.
class CallConnection extends Connection {

    final String callId;
    private final Context context;
    private final boolean outgoing;
    private boolean answered;
    private boolean ended;
    private boolean muted;
    private int route = -1;

    CallConnection(Context context, String callId, String name, String handle, boolean video, boolean outgoing) {
        this.context = context;
        this.callId = callId;
        this.outgoing = outgoing;

        setConnectionCapabilities(CAPABILITY_HOLD | CAPABILITY_SUPPORT_HOLD | CAPABILITY_MUTE
                | (video ? CAPABILITY_SUPPORTS_VT_LOCAL_BIDIRECTIONAL | CAPABILITY_SUPPORTS_VT_REMOTE_BIDIRECTIONAL : 0));
        setAudioModeIsVoip(true);
        setAddress(Uri.fromParts("tel", handle, null), TelecomManager.PRESENTATION_ALLOWED);
        if (name != null && !name.isEmpty()) setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED);
        setVideoState(video ? VideoProfile.STATE_BIDIRECTIONAL : VideoProfile.STATE_AUDIO_ONLY);

        Icon icon = CallKeep.icon(context);
        if (icon != null) setStatusHints(new StatusHints("", icon, new Bundle()));

        if (outgoing) setDialing();
        else {
            setRinging();
            long seconds = CallKeep.ringTimeout(context);
            if (seconds > 0) new Handler(Looper.getMainLooper()).postDelayed(() -> {
                if (answered || ended) return;
                close(DisconnectCause.MISSED);
                emit("hangup");
            }, seconds * 1000);
        }
    }

    // --- what the system UI did -------------------------------------------------------------

    @Override
    public void onAnswer() { answer(); }

    @Override
    public void onAnswer(int videoState) { answer(); }

    // some devices call both onAnswer overloads; the call is answered once
    private void answer() {
        if (answered || ended) return;
        answered = true;
        setActive();
        emit("answer");
        bringToFront();
    }

    @Override
    public void onReject() { reject(); }

    @Override
    public void onReject(int rejectReason) { reject(); }

    @Override
    public void onReject(String replyMessage) { reject(); }

    private void reject() {
        if (ended) return;
        close(DisconnectCause.REJECTED);
        emit("reject");
    }

    @Override
    public void onDisconnect() {
        if (ended) return;
        close(DisconnectCause.LOCAL);
        emit(answered || outgoing ? "hangup" : "reject");
    }

    @Override
    public void onAbort() {
        if (ended) return;
        close(DisconnectCause.CANCELED);
        emit("hangup");
    }

    @Override
    public void onHold() {
        setOnHold();
        emit("hold");
    }

    @Override
    public void onUnhold() {
        setActive();
        emit("unhold");
    }

    @Override
    public void onPlayDtmfTone(char c) {
        emit("DTMF", "digits", String.valueOf(c));
    }

    @Override
    public void onCallAudioStateChanged(CallAudioState state) {
        if (state.isMuted() != muted) {
            muted = state.isMuted();
            emit(muted ? "mute" : "unmute");
        }
        boolean speaker = state.getRoute() == CallAudioState.ROUTE_SPEAKER;
        boolean was = route == CallAudioState.ROUTE_SPEAKER;
        // the first state is where the call starts, not a change anyone made
        if (route != -1 && speaker != was) CallKeep.emit(speaker ? "speakerOn" : "speakerOff", new JSONObject());
        route = state.getRoute();
    }

    // --- what the app does -------------------------------------------------------------------

    void connect() {
        if (!ended) setActive();
    }

    void hold(boolean held) {
        if (ended) return;
        if (held) setOnHold();
        else setActive();
    }

    void speaker(boolean on) {
        setAudioRoute(on ? CallAudioState.ROUTE_SPEAKER : CallAudioState.ROUTE_WIRED_OR_EARPIECE);
    }

    void end() {
        if (!ended) close(DisconnectCause.LOCAL);
    }

    boolean isLive() {
        return getState() == STATE_ACTIVE;
    }

    // --- -------------------------------------------------------------------------------------

    private void close(int cause) {
        ended = true;
        setDisconnected(new DisconnectCause(cause));
        CallConnectionService.forget(callId);
        destroy();
    }

    private void emit(String event, String key, String value) {
        JSONObject body = new JSONObject();
        try {
            body.put("callId", callId);
            if (key != null) body.put(key, value);
        } catch (JSONException ignored) {
        }
        CallKeep.emit(event, body);
    }

    private void emit(String event) {
        emit(event, null, null);
    }

    // the page has the call's media, and it runs only while the app does
    private void bringToFront() {
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (intent == null) return;
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        context.startActivity(intent);
    }
}
