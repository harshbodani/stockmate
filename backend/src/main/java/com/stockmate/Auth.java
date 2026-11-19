package com.stockmate;

import com.sun.net.httpserver.HttpExchange;

import java.security.SecureRandom;
import java.sql.SQLException;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Sign-in sessions. Passwords are checked by the database (bcrypt); this class only keeps the
 * random session token in an HttpOnly, SameSite=Strict cookie and remembers who it belongs to.
 * The user's role is looked up on every request, so a deactivated user is locked out immediately.
 */
final class Auth {
    record User(String username, String role) { }

    private static final String COOKIE = "sm_session";
    private static final long IDLE_MS = 8L * 60 * 60 * 1000;
    private static final int MAX_FAILURES = 10;
    private static final long FAIL_WINDOW_MS = 10L * 60 * 1000;

    private static final class Session {
        final String username;
        volatile long lastSeen = System.currentTimeMillis();
        Session(String username) { this.username = username; }
    }

    private final Database db;
    private final SecureRandom random = new SecureRandom();
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    private final Map<String, long[]> failures = new ConcurrentHashMap<>(); // client address -> {count, window start}

    Auth(Database db) { this.db = db; }

    /** Body is {"username":..., "password":...}. Sets the session cookie on success. */
    String login(HttpExchange ex, String body) throws Exception {
        String client = ex.getRemoteAddress().getAddress().getHostAddress();
        throttle(client);
        String username;
        try {
            username = db.scalar("SELECT fn_login(?::jsonb)->>'username'", body);
        } catch (SQLException e) {
            if ("P0001".equals(e.getSQLState())) {
                recordFailure(client);
                throw new HttpError(401, "Wrong username or password");
            }
            throw e;
        }
        failures.remove(client);
        long now = System.currentTimeMillis();
        sessions.values().removeIf(s -> now - s.lastSeen > IDLE_MS);
        String token = newToken();
        sessions.put(token, new Session(username));
        ex.getResponseHeaders().add("Set-Cookie", COOKIE + "=" + token + "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" + (IDLE_MS / 1000));
        return "{\"ok\":true}";
    }

    String logout(HttpExchange ex) {
        String token = tokenOf(ex);
        if (token != null) sessions.remove(token);
        ex.getResponseHeaders().add("Set-Cookie", COOKIE + "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
        return "{\"ok\":true}";
    }

    /** The signed-in user, or a 401 error. */
    User require(HttpExchange ex) throws Exception {
        String token = tokenOf(ex);
        Session s = token == null ? null : sessions.get(token);
        if (s == null || System.currentTimeMillis() - s.lastSeen > IDLE_MS) {
            if (token != null) sessions.remove(token);
            throw new HttpError(401, "Please sign in");
        }
        String role = db.scalar("SELECT role FROM app_user WHERE username = ? AND active", s.username);
        if (role == null) {
            sessions.remove(token);
            throw new HttpError(401, "Please sign in");
        }
        s.lastSeen = System.currentTimeMillis();
        return new User(s.username, role);
    }

    private String newToken() {
        byte[] b = new byte[32];
        random.nextBytes(b);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
    }

    private static String tokenOf(HttpExchange ex) {
        List<String> headers = ex.getRequestHeaders().get("Cookie");
        if (headers == null) return null;
        for (String h : headers) {
            for (String part : h.split(";")) {
                String p = part.trim();
                if (p.startsWith(COOKIE + "=")) return p.substring(COOKIE.length() + 1);
            }
        }
        return null;
    }

    private void throttle(String client) throws HttpError {
        long[] f = failures.get(client);
        if (f != null && System.currentTimeMillis() - f[1] < FAIL_WINDOW_MS && f[0] >= MAX_FAILURES) {
            throw new HttpError(429, "Too many failed attempts. Please wait a few minutes and try again.");
        }
    }

    private void recordFailure(String client) {
        long now = System.currentTimeMillis();
        failures.merge(client, new long[] {1, now}, (old, fresh) ->
                now - old[1] > FAIL_WINDOW_MS ? fresh : new long[] {old[0] + 1, old[1]});
    }
}
