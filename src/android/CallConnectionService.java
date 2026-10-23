package com.inremote.calls;

import android.os.Bundle;
import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.ConnectionService;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.Iterator;
import java.util.Set;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

// Telecom binds this to make the connection for each call the plugin reported or placed. The calls
// are kept by the app's id, which travels in the request's extras.
public class CallConnectionService extends ConnectionService {

    static final String EXTRA_ID = "callkeep.id";
    static final String EXTRA_NAME = "callkeep.name";
    static final String EXTRA_HANDLE = "callkeep.handle";
    static final String EXTRA_VIDEO = "callkeep.video";

    private static final Map<String, CallConnection> calls = new ConcurrentHashMap<>();
    // A call that is over stays over: declined before the page had its request, it is not rung again
    // when the request arrives. Request ids are never reused, and a few dozen is plenty.
    private static final Set<String> ended = Collections.synchronizedSet(new LinkedHashSet<>());

    static boolean isEnded(String callId) {
        return ended.contains(callId);
    }

    static CallConnection get(String callId) {
        return callId == null ? null : calls.get(callId);
    }

    static List<CallConnection> all() {
        return new ArrayList<>(calls.values());
    }

    static void forget(String callId) {
        if (callId == null) return;
        calls.remove(callId);
        synchronized (ended) {
            ended.add(callId);
            Iterator<String> oldest = ended.iterator();
            while (ended.size() > 50 && oldest.hasNext()) { oldest.next(); oldest.remove(); }
        }
    }

    @Override
    public Connection onCreateIncomingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        return create(request, false);
    }

    @Override
    public Connection onCreateOutgoingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        return create(request, true);
    }

    @Override
    public void onCreateIncomingConnectionFailed(PhoneAccountHandle account, ConnectionRequest request) {
        failed(request, false);
    }

    @Override
    public void onCreateOutgoingConnectionFailed(PhoneAccountHandle account, ConnectionRequest request) {
        failed(request, true);
    }

    private Connection create(ConnectionRequest request, boolean outgoing) {
        Bundle extras = extrasOf(request, outgoing);
        String callId = extras.getString(EXTRA_ID);
        CallConnection connection = new CallConnection(this, callId, extras.getString(EXTRA_NAME),
                extras.getString(EXTRA_HANDLE, callId), extras.getBoolean(EXTRA_VIDEO), outgoing);
        calls.put(callId, connection);
        return connection;
    }

    // Telecom refused the call - another call it could not hold, or a phone account switched off -
    // and the page hears it as the call ending
    private void failed(ConnectionRequest request, boolean outgoing) {
        String callId = extrasOf(request, outgoing).getString(EXTRA_ID);
        if (callId == null) return;
        forget(callId);
        CallKeep.emit("hangup", CallKeep.body(callId));
    }

    // the plugin's extras arrive nested on some versions and flattened into the request on others
    private static Bundle extrasOf(ConnectionRequest request, boolean outgoing) {
        Bundle extras = request.getExtras() != null ? request.getExtras() : new Bundle();
        Bundle nested = extras.getBundle(outgoing ? TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS : TelecomManager.EXTRA_INCOMING_CALL_EXTRAS);
        return nested != null && nested.containsKey(EXTRA_ID) ? nested : extras;
    }
}
