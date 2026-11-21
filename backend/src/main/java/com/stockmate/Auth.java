package com.stockmate;

import com.sun.net.httpserver.HttpExchange;

import java.security.SecureRandom;
import java.sql.SQLException;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Sign-in sessions. Passwords are checked by the database (bcrypt); this class keeps a random 256-bit session token in an
 * HttpOnly, SameSite=Strict cookie (Secure when COOKIE_SECURE=true) and remembers who it belongs to.
 *
 *  - The user's role and "must change password" flag are looked up on every request, so deactivation and role changes apply immediately.
 *  - Sessions end after 4 hours without use and in any case after 12 hours; at most 5 per user.
 *  - Changing or resetting a password ends the user's other sessions.
 *  - Failed sign-ins are limited per address AND per username, and every sign-in, failure and logout is written to the audit log.
 */
final class Auth {
    record User(String username, String role, boolean mustChange) { }

    private static final String COOKIE = "sm_session";
    private static final long IDLE_MS = 4L * 60 * 60 * 1000;
    private static final long ABSOLUTE_MS = 12L * 60 * 60 * 1000;
    private static final int MAX_SESSIONS_PER_USER = 5;
    private static final int MAX_FAILURES = 10;
    private static final long FAIL_WINDOW_MS = 10L * 60 * 1000;
    private static final int MAX_TRACKED = 10_000;

    private static final class Session {
        final String username;
        final long created = System.currentTimeMillis();
        volatile long lastSeen = created;
        Session(String username) { this.username = username; }
    }

    private final Database db;
    private final boolean secureCookie;
    private final boolean trustProxy;
    private final SecureRandom random = new SecureRandom();
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    private final Map<String, long[]> byClient = new ConcurrentHashMap<>();   // client address -> {count, window start}
    private final Map<String, long[]> byUser = new ConcurrentHashMap<>();     // username -> {count, window start}

    Auth(Database db, boolean secureCookie, boolean trustProxy) {
        this.db = db;
        this.secureCookie = secureCookie;
        this.trustProxy = trustProxy;
    }

    /** The caller's address. Behind a trusted reverse proxy this is the last X-Forwarded-For entry (the one the proxy added). */
    String client(HttpExchange ex) {
        if (trustProxy) {
            String xff = ex.getRequestHeaders().getFirst("X-Forwarded-For");
            if (xff != null && !xff.isBlank()) {
                String[] parts = xff.split(",");
                return parts[parts.length - 1].trim();
            }
        }
        return ex.getRemoteAddress().getAddress().getHostAddress();
    }

    /** Body is {"username":..., "password":...}. Sets the session cookie on success. */
    String login(HttpExchange ex, String body) throws Exception {
        String client = client(ex);
        String attempted = Json.str(Json.obj(Json.parse(body)).get("username")).trim().toLowerCase();
        if (attempted.length() > 64) attempted = attempted.substring(0, 64);
        check(byClient, client);
        check(byUser, attempted);
        String result;
        try {
            result = db.scalar("SELECT fn_login(?::jsonb)::text", body);
        } catch (SQLException e) {
            if ("P0001".equals(e.getSQLState())) {
                fail(byClient, client);
                fail(byUser, attempted);
                audit(attempted, "LOGIN_FAILED", client);
                throw new HttpError(401, "Wrong username or password");
            }
            throw e;
        }
        var info = Json.obj(Json.parse(result));
        String username = Json.str(info.get("username"));
        byClient.remove(client);
        byUser.remove(attempted);

        long now = System.currentTimeMillis();
        sessions.values().removeIf(s -> now - s.lastSeen > IDLE_MS || now - s.created > ABSOLUTE_MS);
        // keep at most MAX_SESSIONS_PER_USER: drop the oldest
        List<Map.Entry<String, Session>> mine = sessions.entrySet().stream().filter(e -> e.getValue().username.equals(username))
                .sorted((a, b) -> Long.compare(a.getValue().created, b.getValue().created)).toList();
        for (int i = 0; i <= mine.size() - MAX_SESSIONS_PER_USER; i++) sessions.remove(mine.get(i).getKey());

        String token = newToken();
        sessions.put(token, new Session(username));
        ex.getResponseHeaders().add("Set-Cookie", COOKIE + "=" + token + "; Path=/; HttpOnly; SameSite=Strict" + (secureCookie ? "; Secure" : "")
                + "; Max-Age=" + (ABSOLUTE_MS / 1000));
        audit(username, "LOGIN", client);
        return "{\"ok\":true,\"must_change\":" + Boolean.TRUE.equals(info.get("must_change")) + "}";
    }

    String logout(HttpExchange ex) {
        String token = tokenOf(ex);
        Session s = token == null ? null : sessions.remove(token);
        if (s != null) audit(s.username, "LOGOUT", client(ex));
        ex.getResponseHeaders().add("Set-Cookie", COOKIE + "=; Path=/; HttpOnly; SameSite=Strict" + (secureCookie ? "; Secure" : "") + "; Max-Age=0");
        return "{\"ok\":true}";
    }

    /** The signed-in user, or a 401 error. */
    User require(HttpExchange ex) throws Exception {
        String token = tokenOf(ex);
        Session s = token == null ? null : sessions.get(token);
        long now = System.currentTimeMillis();
        if (s == null || now - s.lastSeen > IDLE_MS || now - s.created > ABSOLUTE_MS) {
            if (token != null) sessions.remove(token);
            throw new HttpError(401, "Please sign in");
        }
        String row = db.scalar("SELECT role || ':' || must_change::text FROM app_user WHERE username = ? AND active", s.username);
        if (row == null) {
            sessions.remove(token);
            throw new HttpError(401, "Please sign in");
        }
        s.lastSeen = now;
        String[] p = row.split(":");
        return new User(s.username, p[0], "true".equals(p[1]));
    }

    /** A user changes their own password. Wrong "current password" guesses count like failed sign-ins. */
    String changePassword(HttpExchange ex, User user, String body) throws Exception {
        check(byUser, user.username());
        String res;
        try {
            res = db.scalar("SELECT fn_change_password(?, ?::jsonb)::text", user.username(), body);
        } catch (SQLException e) {
            if ("P0001".equals(e.getSQLState()) && e.getMessage() != null && e.getMessage().contains("Current password is wrong")) {
                fail(byUser, user.username());
                audit(user.username(), "PASSWORD_CHANGE_FAILED", client(ex));
            }
            throw e;
        }
        byUser.remove(user.username());
        revokeUser(user.username(), tokenOf(ex));   // everyone else signed in as this user is signed out
        return res;
    }

    /** End all sessions of a user, except the one with keepToken (may be null). */
    void revokeUser(String username, String keepToken) {
        sessions.entrySet().removeIf(e -> e.getValue().username.equals(username) && !e.getKey().equals(keepToken));
    }

    private void audit(String username, String action, String target) {
        try {
            db.update("INSERT INTO audit_log (username, action, target) VALUES (left(?, 64), ?, left(?, 200))", username, action, target);
        } catch (SQLException e) {
            System.err.println("audit log failed: " + e.getMessage());
        }
    }

    private String newToken() {
        byte[] b = new byte[32];
        random.nextBytes(b);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
    }

    static String tokenOf(HttpExchange ex) {
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

    private static void check(Map<String, long[]> map, String key) throws HttpError {
        long[] f = map.get(key);
        if (f != null && System.currentTimeMillis() - f[1] < FAIL_WINDOW_MS && f[0] >= MAX_FAILURES) {
            throw new HttpError(429, "Too many failed attempts. Please wait a few minutes and try again.");
        }
    }

    private static void fail(Map<String, long[]> map, String key) {
        long now = System.currentTimeMillis();
        if (map.size() > MAX_TRACKED) map.values().removeIf(v -> now - v[1] > FAIL_WINDOW_MS);
        if (map.size() > MAX_TRACKED) return;   // under a flood of distinct names, do not grow without bound
        map.merge(key, new long[] {1, now}, (old, fresh) -> now - old[1] > FAIL_WINDOW_MS ? fresh : new long[] {old[0] + 1, old[1]});
    }
}
