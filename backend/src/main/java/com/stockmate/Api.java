package com.stockmate;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * HTTP layer. Routes:
 *   GET    /api/{entity}[?column=value]   list (optionally filtered)
 *   GET    /api/{entity}/{id}             one record
 *   POST   /api/{entity}                  create   (JSON body)
 *   PUT    /api/{entity}/{id}             update   (JSON body, only the fields sent)
 *   DELETE /api/{entity}/{id}             delete
 *   POST   /api/rpc/{function}            business action, e.g. fn_so_deliver  (JSON body)
 *   GET    /api/dashboard                 summary numbers
 *   anything else                         static files from the frontend folder
 * All business rules live in the database (db/functions.sql); this class only routes requests.
 */
public final class Api implements HttpHandler {

    /** read = table or view used for GET, write = table used for POST/PUT/DELETE (null = read-only). */
    private record Entity(String read, String write) { }

    private static final Map<String, Entity> ENTITIES = new LinkedHashMap<>();

    private static void rw(String name) { ENTITIES.put(name, new Entity(name, name)); }
    private static void rw(String name, String view) { ENTITIES.put(name, new Entity(view, name)); }
    private static void ro(String name, String view) { ENTITIES.put(name, new Entity(view, null)); }

    static {
        rw("partner"); rw("warehouse"); rw("product", "v_product"); ro("stock", "v_stock"); ro("stock_move", "stock_move");
        rw("crm_lead"); rw("crm_activity");
        rw("sales_order", "v_sales_order"); rw("sales_order_line");
        rw("purchase_order", "v_purchase_order"); rw("purchase_order_line");
        ro("invoice", "v_invoice"); rw("payment");
        rw("bom"); rw("bom_line"); rw("work_center"); rw("production_order", "v_production_order"); rw("work_order");
        rw("project", "v_project"); rw("task"); rw("timesheet", "v_timesheet");
        rw("employee"); ro("payslip", "payslip");
        rw("cash_register"); ro("pos_sale", "pos_sale"); ro("pos_sale_line", "pos_sale_line");
        ro("costing", "v_costing"); ro("ageing", "v_ageing"); ro("reorder", "v_reorder");
        ro("staff", "v_staff"); ro("app_user", "v_app_user"); ro("audit_log", "audit_log");
    }

    /** Functions in db/functions.sql that the browser is allowed to call. */
    private static final Set<String> RPC = Set.of(
            "fn_adjust_stock", "fn_transfer_stock", "fn_reorder_create_pos", "fn_crm_convert",
            "fn_create_user", "fn_set_password", "fn_set_user_active",
            "fn_so_confirm", "fn_so_deliver", "fn_so_cancel",
            "fn_po_confirm", "fn_po_receive", "fn_po_cancel",
            "fn_create_invoice",
            "fn_mo_start", "fn_mo_complete", "fn_mo_cancel",
            "fn_generate_payslip", "fn_pos_checkout");

    private static final Map<String, String> MIME = Map.of(
            "html", "text/html; charset=utf-8", "css", "text/css; charset=utf-8",
            "js", "application/javascript; charset=utf-8", "svg", "image/svg+xml",
            "png", "image/png", "ico", "image/x-icon", "json", "application/json; charset=utf-8");

    private static final int MAX_BODY = 1_000_000;

    private final Database db;
    private final Auth auth;
    private final Path webRoot;
    private final Map<String, Set<String>> columnCache = new ConcurrentHashMap<>();

    public Api(Database db, Path webRoot) {
        this.db = db;
        this.auth = new Auth(db);
        this.webRoot = webRoot;
    }

    @Override
    public void handle(HttpExchange ex) throws IOException {
        try {
            String path = ex.getRequestURI().getPath();
            if (path.equals("/api") || path.startsWith("/api/")) {
                json(ex, 200, dispatch(ex, path.length() > 5 ? path.substring(5) : ""));
            } else {
                serveStatic(ex, path);
            }
        } catch (HttpError e) {
            json(ex, e.status, "{\"error\":" + quote(e.getMessage()) + "}");
        } catch (SQLException e) {
            String state = e.getSQLState() == null ? "" : e.getSQLState();
            boolean userError = state.startsWith("23") || state.startsWith("22") || state.equals("P0001");
            String msg = state.equals("23503") && e.getMessage().contains("update or delete")
                    ? "Cannot delete: this record is used by other records" : cleanMessage(e);
            json(ex, userError ? 400 : 500, "{\"error\":" + quote(msg) + "}");
        } catch (Exception e) {
            e.printStackTrace();
            json(ex, 500, "{\"error\":\"Internal server error\"}");
        } finally {
            ex.close();
        }
    }

    // ------------------------------------------------------------------ sign-in, permissions, audit

    private String dispatch(HttpExchange ex, String rest) throws Exception {
        String method = ex.getRequestMethod();
        if (rest.equals("login") && method.equals("POST")) return auth.login(ex, requireBody(ex));
        if (rest.equals("logout") && method.equals("POST")) return auth.logout(ex);

        Auth.User user = auth.require(ex);          // everything below needs a signed-in user
        if (rest.equals("me") && method.equals("GET")) return me(user);
        if (rest.equals("password") && method.equals("POST")) {
            return db.scalar("SELECT fn_change_password(?, ?::jsonb)::text", user.username(), requireBody(ex));
        }
        String result = route(ex, rest, user);
        if (!method.equals("GET")) audit(user, method, rest);
        return result;
    }

    /** Who is signed in and what they may do; the frontend uses this to hide buttons they cannot use. */
    private String me(Auth.User u) throws SQLException {
        String base = db.scalar("SELECT to_jsonb(x)::text FROM (SELECT username, full_name, role FROM app_user WHERE username = ?) x", u.username());
        List<String> read = ENTITIES.keySet().stream().filter(k -> Permissions.canRead(u.role(), k)).toList();
        List<String> write = ENTITIES.entrySet().stream()
                .filter(e -> e.getValue().write() != null && Permissions.canWrite(u.role(), e.getKey())).map(Map.Entry::getKey).toList();
        List<String> rpc = RPC.stream().filter(f -> Permissions.canRpc(u.role(), f)).sorted().toList();
        return base.substring(0, base.length() - 1) + ",\"can_read\":" + array(read) + ",\"can_write\":" + array(write)
                + ",\"can_rpc\":" + array(rpc) + ",\"can_dashboard\":" + Permissions.canDashboard(u.role()) + "}";
    }

    private static String array(List<String> items) {
        StringBuilder b = new StringBuilder("[");
        for (String s : items) b.append(b.length() > 1 ? "," : "").append(quote(s));
        return b.append(']').toString();
    }

    /** Who changed what. A failure to log must never block the work itself. */
    private void audit(Auth.User u, String method, String rest) {
        try {
            String action = rest.startsWith("rpc/") ? "ACTION" : method;
            String target = rest.startsWith("rpc/") ? rest.substring(4) : rest;
            db.update("INSERT INTO audit_log (username, action, target) VALUES (?, ?, ?)", u.username(), action, target);
        } catch (SQLException e) {
            System.err.println("audit log failed: " + e.getMessage());
        }
    }

    // ------------------------------------------------------------------ routing

    private String route(HttpExchange ex, String rest, Auth.User user) throws Exception {
        String method = ex.getRequestMethod();
        String[] seg = rest.isEmpty() ? new String[0] : rest.split("/");

        if (seg.length == 1 && seg[0].equals("dashboard") && method.equals("GET")) {
            if (!Permissions.canDashboard(user.role())) throw new HttpError(403, "Your role is not allowed to view the dashboard");
            return db.scalar("SELECT fn_dashboard()::text");
        }
        if (seg.length == 2 && seg[0].equals("rpc") && method.equals("POST")) {
            if (!RPC.contains(seg[1])) throw new HttpError(404, "Unknown action");
            if (!Permissions.canRpc(user.role(), seg[1])) throw new HttpError(403, "Your role is not allowed to do this");
            String body = readBody(ex);
            return db.scalar("SELECT " + seg[1] + "(?::jsonb)::text", body.isBlank() ? "{}" : body);
        }
        if (seg.length == 0 || seg.length > 2) throw new HttpError(404, "Not found");

        Entity e = ENTITIES.get(seg[0]);
        if (e == null) throw new HttpError(404, "Unknown resource: " + seg[0]);
        String id = seg.length == 2 ? requireId(seg[1]) : null;
        boolean allowed = method.equals("GET") ? Permissions.canRead(user.role(), seg[0]) : Permissions.canWrite(user.role(), seg[0]);
        if (!allowed) throw new HttpError(403, "Your role is not allowed to " + (method.equals("GET") ? "view this" : "change this"));

        switch (method) {
            case "GET":
                return id == null ? list(e, ex) : one(e, id);
            case "POST":
                if (id != null) throw new HttpError(405, "Method not allowed");
                return db.scalar("SELECT api_insert(?, ?::jsonb)::text", writable(e), requireBody(ex));
            case "PUT":
                if (id == null) throw new HttpError(405, "Method not allowed");
                return db.scalar("SELECT api_update(?, ?::int, ?::jsonb)::text", writable(e), id, requireBody(ex));
            case "DELETE":
                if (id == null) throw new HttpError(405, "Method not allowed");
                int n = db.update("DELETE FROM " + writable(e) + " WHERE id = ?::int", id);
                if (n == 0) throw new HttpError(404, "Record not found");
                return "{\"deleted\":" + n + "}";
            default:
                throw new HttpError(405, "Method not allowed");
        }
    }

    private String list(Entity e, HttpExchange ex) throws Exception {
        Set<String> cols = columns(e.read());
        StringBuilder where = new StringBuilder();
        List<String> params = new java.util.ArrayList<>();
        for (Map.Entry<String, String> q : queryParams(ex).entrySet()) {
            if (!cols.contains(q.getKey())) throw new HttpError(400, "Unknown filter column: " + q.getKey());
            where.append(where.length() == 0 ? " WHERE " : " AND ").append('"').append(q.getKey()).append("\"::text = ?");
            params.add(q.getValue());
        }
        String order = cols.contains("id") ? " ORDER BY id DESC" : "";
        String sql = "SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)::text FROM "
                + "(SELECT * FROM " + e.read() + where + order + " LIMIT 1000) x";
        return db.scalar(sql, params.toArray(new String[0]));
    }

    private String one(Entity e, String id) throws Exception {
        if (!columns(e.read()).contains("id")) throw new HttpError(404, "Not found");
        String r = db.scalar("SELECT to_jsonb(x)::text FROM " + e.read() + " x WHERE id = ?::int", id);
        if (r == null) throw new HttpError(404, "Record not found");
        return r;
    }

    // ------------------------------------------------------------------ helpers

    /** Column names of a table/view, read once from the catalog. Table names only come from the fixed whitelist. */
    private Set<String> columns(String relation) throws SQLException {
        Set<String> cached = columnCache.get(relation);
        if (cached != null) return cached;
        String csv = db.scalar("SELECT string_agg(column_name, ',') FROM information_schema.columns "
                + "WHERE table_schema = 'public' AND table_name = ?", relation);
        Set<String> cols = csv == null ? new HashSet<>() : new HashSet<>(Arrays.asList(csv.split(",")));
        columnCache.put(relation, cols);
        return cols;
    }

    private static String writable(Entity e) throws HttpError {
        if (e.write() == null) throw new HttpError(405, "This resource is read-only");
        return e.write();
    }

    private static String requireId(String s) throws HttpError {
        if (!s.matches("\\d{1,9}")) throw new HttpError(400, "Invalid id");
        return s;
    }

    private static String readBody(HttpExchange ex) throws IOException, HttpError {
        byte[] b = ex.getRequestBody().readNBytes(MAX_BODY + 1);
        if (b.length > MAX_BODY) throw new HttpError(413, "Request too large");
        String type = ex.getRequestHeaders().getFirst("Content-Type");
        if (b.length > 0 && (type == null || !type.toLowerCase().startsWith("application/json"))) {
            throw new HttpError(415, "Send JSON (Content-Type: application/json)");
        }
        return new String(b, StandardCharsets.UTF_8);
    }

    private static String requireBody(HttpExchange ex) throws IOException, HttpError {
        String body = readBody(ex).trim();
        if (!body.startsWith("{")) throw new HttpError(400, "Expected a JSON object");
        return body;
    }

    private static Map<String, String> queryParams(HttpExchange ex) {
        Map<String, String> m = new LinkedHashMap<>();
        String q = ex.getRequestURI().getRawQuery();
        if (q == null || q.isEmpty()) return m;
        for (String pair : q.split("&")) {
            int i = pair.indexOf('=');
            String k = URLDecoder.decode(i < 0 ? pair : pair.substring(0, i), StandardCharsets.UTF_8);
            String v = i < 0 ? "" : URLDecoder.decode(pair.substring(i + 1), StandardCharsets.UTF_8);
            m.put(k, v);
        }
        return m;
    }

    /** First line of the database message without the "ERROR: " prefix. */
    private static String cleanMessage(SQLException e) {
        String m = e.getMessage() == null ? "Database error" : e.getMessage();
        int nl = m.indexOf('\n');
        if (nl > 0) m = m.substring(0, nl);
        return m.startsWith("ERROR: ") ? m.substring(7) : m;
    }

    private static String quote(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    private static void json(HttpExchange ex, int status, String body) throws IOException {
        byte[] bytes = (body == null ? "null" : body).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.getResponseHeaders().set("Cache-Control", "no-store");
        ex.sendResponseHeaders(status, bytes.length);
        ex.getResponseBody().write(bytes);
    }

    private void serveStatic(HttpExchange ex, String path) throws IOException {
        if (!ex.getRequestMethod().equals("GET")) {
            ex.sendResponseHeaders(405, -1);
            return;
        }
        Path file = webRoot.resolve("." + (path.equals("/") ? "/index.html" : path)).normalize();
        if (!file.startsWith(webRoot) || !Files.isRegularFile(file)) {
            ex.sendResponseHeaders(404, -1);
            return;
        }
        String name = file.getFileName().toString();
        String ext = name.contains(".") ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : "";
        byte[] bytes = Files.readAllBytes(file);
        ex.getResponseHeaders().set("Content-Type", MIME.getOrDefault(ext, "application/octet-stream"));
        ex.sendResponseHeaders(200, bytes.length);
        ex.getResponseBody().write(bytes);
    }
}
