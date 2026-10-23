package com.inremote.calls;

import android.Manifest;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Bundle;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telecom.VideoProfile;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

// `CordovaCall` to the page: the system call UI, through Telecom, for several calls at once.
//
// The phone account is a managed one, so the calls are the system dialer's to show - the same screen,
// the same hold and swap, as a phone call. Android asks the user to switch such an account on once;
// until they have, a call cannot be reported, and the settings screen is offered instead.
public class CallKeep extends CordovaPlugin {

    private static final String PREFS = "callkeep";
    // what cordova-plugin-callkit registered, left behind by an update that replaced it
    private static final String LEGACY_SERVICE = "com.dmarc.cordovacall.MyConnectionService";
    private static final int CALL_PHONE_REQUEST = 7301;

    private static CallKeep instance;
    // events nobody listened for yet - an answer from the lock screen while the page loads
    private static final Map<String, List<JSONObject>> pending = new HashMap<>();

    private final Map<String, List<CallbackContext>> listeners = new HashMap<>();
    private TelecomManager telecom;
    private PhoneAccountHandle account;
    private boolean askedToEnable;
    private Runnable afterPermission;
    private CallbackContext permissionCallback;

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);
        Context context = context();
        telecom = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
        String id = appLabel(context);
        account = new PhoneAccountHandle(new ComponentName(context, CallConnectionService.class), id);
        try {
            telecom.unregisterPhoneAccount(new PhoneAccountHandle(new ComponentName(context.getPackageName(), LEGACY_SERVICE), id));
        } catch (RuntimeException ignored) {
        }
        registerAccount();
        synchronized (CallKeep.class) {
            instance = this;
        }
    }

    // a new page: the callbacks belonged to the one that went
    @Override
    public void onReset() {
        synchronized (CallKeep.class) {
            listeners.clear();
        }
    }

    @Override
    public void onDestroy() {
        synchronized (CallKeep.class) {
            if (instance == this) instance = null;
        }
    }

    // --- events ----------------------------------------------------------------------------------

    static JSONObject body(String callId) {
        JSONObject body = new JSONObject();
        try {
            body.put("callId", callId);
        } catch (JSONException ignored) {
        }
        return body;
    }

    static void emit(String event, JSONObject body) {
        synchronized (CallKeep.class) {
            List<CallbackContext> list = instance == null ? null : instance.listeners.get(event);
            if (list == null || list.isEmpty()) {
                if (!pending.containsKey(event)) pending.put(event, new ArrayList<>());
                pending.get(event).add(body);
                return;
            }
            for (CallbackContext callback : list) send(callback, body);
        }
    }

    private static void send(CallbackContext callback, JSONObject body) {
        PluginResult result = new PluginResult(PluginResult.Status.OK, body);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    // --- settings --------------------------------------------------------------------------------

    private Context context() {
        return cordova.getActivity().getApplicationContext();
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String appLabel(Context context) {
        return context.getApplicationInfo().loadLabel(context.getPackageManager()).toString();
    }

    static long ringTimeout(Context context) {
        return prefs(context).getLong("ringTimeout", 0);
    }

    static Icon icon(Context context) {
        String name = prefs(context).getString("icon", null);
        if (name == null) return null;
        int id = context.getResources().getIdentifier(name, "drawable", context.getPackageName());
        return id == 0 ? null : Icon.createWithResource(context, id);
    }

    private void registerAccount() {
        Context context = context();
        String label = prefs(context).getString("appName", appLabel(context));
        PhoneAccount.Builder builder = new PhoneAccount.Builder(account, label)
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER | PhoneAccount.CAPABILITY_VIDEO_CALLING
                        | PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING)
                .addSupportedUriScheme(PhoneAccount.SCHEME_TEL);
        Icon icon = icon(context);
        if (icon != null) builder.setIcon(icon);
        telecom.registerPhoneAccount(builder.build());
    }

    private boolean accountEnabled() {
        PhoneAccount registered = telecom.getPhoneAccount(account);
        return registered != null && registered.isEnabled();
    }

    // the user switches a calling account on in the system settings, and only they can
    private boolean ensureAccount(CallbackContext callback) {
        if (accountEnabled()) return true;
        if (!askedToEnable) {
            askedToEnable = true;
            Intent intent = new Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            context().startActivity(intent);
        }
        callback.error("You need to accept phone account permissions in order to send and receive calls");
        return false;
    }

    // --- commands --------------------------------------------------------------------------------

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callback) throws JSONException {
        switch (action) {
            case "registerEvent": registerEvent(args.getString(0), callback); return true;
            case "receiveCall": receiveCall(args, callback); return true;
            case "sendCall": sendCall(args, callback); return true;
            case "connectCall": for (CallConnection c : targets(args)) c.connect(); callback.success(); return true;
            case "endCall": for (CallConnection c : targets(args)) c.end(); callback.success(); return true;
            case "setOnHold": setOnHold(args, callback); return true;
            case "mute": muteMicrophone(true); callback.success(); return true;
            case "unmute": muteMicrophone(false); callback.success(); return true;
            case "speakerOn": speaker(true); callback.success(); return true;
            case "speakerOff": speaker(false); callback.success(); return true;
            case "setAppName": setAppName(args.optString(0, ""), callback); return true;
            case "setIcon": setIcon(args.optString(0, ""), callback); return true;
            case "setVideo": prefs(context()).edit().putBoolean("video", args.optBoolean(0)).apply(); callback.success(); return true;
            case "setRingTimeout": prefs(context()).edit().putLong("ringTimeout", args.optLong(0)).apply(); callback.success(); return true;
            // the dialer rings with the user's own ringtone, keeps its own log, and offers its own keypad
            case "setRingtone":
            case "setIncludeInRecents":
            case "setDTMFState": callback.success(); return true;
            // VoIP push is iOS's; Android's calls arrive through the ordinary push plugin
            case "init": callback.error("VoIP push is iOS only"); return true;
            default: return false;
        }
    }

    private void registerEvent(String event, CallbackContext callback) {
        synchronized (CallKeep.class) {
            if (!listeners.containsKey(event)) listeners.put(event, new ArrayList<>());
            listeners.get(event).add(callback);
            List<JSONObject> waiting = pending.remove(event);
            if (waiting != null) for (JSONObject body : waiting) send(callback, body);
        }
    }

    // the call a command names, or every call when it names none
    private static List<CallConnection> targets(JSONArray args) {
        String callId = args.isNull(0) ? null : args.optString(0, null);
        if (callId == null) return CallConnectionService.all();
        List<CallConnection> list = new ArrayList<>();
        CallConnection c = CallConnectionService.get(callId);
        if (c != null) list.add(c);
        return list;
    }

    private Bundle callExtras(JSONArray args, String callId) {
        Bundle extras = new Bundle();
        extras.putString(CallConnectionService.EXTRA_ID, callId);
        extras.putString(CallConnectionService.EXTRA_NAME, args.optString(0, ""));
        extras.putString(CallConnectionService.EXTRA_HANDLE, args.isNull(2) ? callId : args.optString(2, callId));
        extras.putBoolean(CallConnectionService.EXTRA_VIDEO, args.isNull(3) ? prefs(context()).getBoolean("video", false) : args.optBoolean(3));
        return extras;
    }

    private static String callIdOf(JSONArray args) {
        return args.isNull(1) ? java.util.UUID.randomUUID().toString() : args.optString(1);
    }

    private void receiveCall(JSONArray args, CallbackContext callback) {
        String callId = callIdOf(args);
        // already reported: binding to it is all that is asked
        if (CallConnectionService.get(callId) != null) { callback.success(); return; }
        if (CallConnectionService.isEnded(callId)) { callback.error("Call already ended"); return; }
        if (args.optString(0, "").isEmpty()) { callback.error("Caller id can't be empty"); return; }
        if (!ensureAccount(callback)) return;

        Bundle extras = callExtras(args, callId);
        Bundle request = new Bundle(extras);
        request.putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, extras);
        request.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts(PhoneAccount.SCHEME_TEL, extras.getString(CallConnectionService.EXTRA_HANDLE), null));
        try {
            telecom.addNewIncomingCall(account, request);
            callback.success();
        } catch (RuntimeException e) {
            callback.error(e.getMessage());
        }
    }

    private void sendCall(final JSONArray args, final CallbackContext callback) {
        final String callId = callIdOf(args);
        if (CallConnectionService.get(callId) != null) { callback.success(); return; }
        if (args.optString(0, "").isEmpty()) { callback.error("The caller id can't be empty"); return; }
        if (!ensureAccount(callback)) return;

        // a managed account places calls with the same permission the dialer does
        if (!cordova.hasPermission(Manifest.permission.CALL_PHONE)) {
            afterPermission = () -> sendCall(args, callback);
            permissionCallback = callback;
            cordova.requestPermission(this, CALL_PHONE_REQUEST, Manifest.permission.CALL_PHONE);
            return;
        }

        Bundle extras = callExtras(args, callId);
        Bundle request = new Bundle();
        request.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, account);
        request.putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, extras);
        if (extras.getBoolean(CallConnectionService.EXTRA_VIDEO)) {
            request.putInt(TelecomManager.EXTRA_START_CALL_WITH_VIDEO_STATE, VideoProfile.STATE_BIDIRECTIONAL);
        }
        try {
            telecom.placeCall(Uri.fromParts(PhoneAccount.SCHEME_TEL, extras.getString(CallConnectionService.EXTRA_HANDLE), null), request);
            callback.success();
        } catch (RuntimeException e) {
            callback.error(e.getMessage());
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != CALL_PHONE_REQUEST) return;
        Runnable next = afterPermission;
        CallbackContext callback = permissionCallback;
        afterPermission = null;
        permissionCallback = null;
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        if (granted && next != null) next.run();
        else if (callback != null) callback.error("Permission to place calls was denied");
    }

    private void setOnHold(JSONArray args, CallbackContext callback) {
        CallConnection c = CallConnectionService.get(args.optString(0, null));
        if (c == null) { callback.error("No such call"); return; }
        c.hold(args.optBoolean(1));
        callback.success();
    }

    private void muteMicrophone(boolean on) {
        android.media.AudioManager audio = (android.media.AudioManager) context().getSystemService(Context.AUDIO_SERVICE);
        audio.setMicrophoneMute(on);
    }

    // the route belongs to the live call; Telecom moves it for every call at once
    private void speaker(boolean on) {
        for (CallConnection c : CallConnectionService.all()) {
            if (c.isLive()) { c.speaker(on); return; }
        }
    }

    private void setAppName(String name, CallbackContext callback) {
        if (name.isEmpty()) { callback.error("App Name Can't Be Empty"); return; }
        prefs(context()).edit().putString("appName", name).apply();
        registerAccount();
        callback.success();
    }

    private void setIcon(String name, CallbackContext callback) {
        Context context = context();
        if (context.getResources().getIdentifier(name, "drawable", context.getPackageName()) == 0) {
            callback.error("This icon does not exist");
            return;
        }
        prefs(context).edit().putString("icon", name).apply();
        registerAccount();
        callback.success();
    }
}
