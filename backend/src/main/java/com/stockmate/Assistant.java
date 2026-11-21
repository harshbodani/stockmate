package com.stockmate;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.sql.SQLException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * Answers short spoken or typed questions about the business ("how much stock of cartridges?").
 *
 * 1. Built-in intents run fixed, read-only queries and respect the signed-in user's role. They work offline.
 * 2. If nothing matches and OPENJARVIS_URL is set, the question goes to an OpenJarvis server (OpenAI-compatible
 *    /v1/chat/completions) together with a small business snapshot the user is allowed to see.
 *    OpenJarvis never gets database access or the ability to change anything.
 */
final class Assistant {
    private static final Set<String> STOP = Set.of("how", "much", "many", "what", "whats", "is", "are", "the", "of", "in", "do", "we", "have",
            "stock", "left", "available", "for", "any", "there", "show", "tell", "me", "about", "and", "our", "units", "pieces", "quantity",
            "check", "current", "on", "hand", "please", "got", "does", "a", "an", "to", "my");

    private final Database db;
    private final String ojUrl = safeUrl(System.getenv("OPENJARVIS_URL"));
    private final String ojKey = System.getenv("OPENJARVIS_API_KEY");
    private final String ojModel = System.getenv().getOrDefault("OPENJARVIS_MODEL", "default");
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    Assistant(Database db) { this.db = db; }

    /**
     * Business figures are sent to this URL, so it must be https, or plain http only to this machine (localhost).
     * Anything else is ignored with a warning rather than sending data over an open network.
     */
    private static String safeUrl(String url) {
        if (url == null || url.isBlank()) return null;
        try {
            URI u = URI.create(url.trim());
            String host = u.getHost() == null ? "" : u.getHost().toLowerCase(Locale.ROOT);
            boolean local = host.equals("localhost") || host.equals("127.0.0.1") || host.equals("::1") || host.equals("[::1]");
            if ("https".equals(u.getScheme()) || ("http".equals(u.getScheme()) && local)) return url.trim();
        } catch (IllegalArgumentException ignored) { /* falls through */ }
        System.err.println("WARNING: OPENJARVIS_URL ignored. Use https:// (or http://localhost) so business data is not sent unencrypted.");
        return null;
    }

    boolean openJarvisConfigured() { return ojUrl != null && !ojUrl.isBlank(); }

    /** Returns {"reply": "...", "source": "stockmate"|"openjarvis"}. */
    String answer(Auth.User user, String rawText) throws SQLException {
        String text = rawText == null ? "" : rawText.trim();
        if (text.length() > 300) text = text.substring(0, 300);
        String q = text.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9 ]", " ").replaceAll("\\s+", " ").trim();
        if (q.isEmpty()) return reply("I did not hear a question. Try: how much stock of cartridges?", "stockmate");

        String r = builtIn(user, q);
        if (r != null) return reply(r, "stockmate");
        if (openJarvisConfigured()) {
            try {
                String o = askOpenJarvis(user, text);
                if (o != null && !o.isBlank()) return reply(o, "openjarvis");
            } catch (Exception e) {
                System.err.println("OpenJarvis request failed: " + e.getMessage());
                return reply("I could not reach the OpenJarvis assistant just now. I can still answer questions about stock, overdue invoices, expiring lots and sales.", "stockmate");
            }
        }
        return reply("Sorry, I can answer questions about stock levels, low stock, money owed, overdue invoices, expiring lots, today's sales, open orders and failed quality checks.", "stockmate");
    }

    // ------------------------------------------------------------------ built-in intents

    private String builtIn(Auth.User u, String q) throws SQLException {
        String role = u.role();
        boolean dash = Permissions.canDashboard(role);
        if (q.matches(".*\\b(help|what can you do)\\b.*") || q.matches("^(hi|hello|hey)( stockmate)?$")) {
            return "I can tell you stock levels, low stock, money to collect, overdue invoices, expiring lots, today's sales, open orders and failed quality checks.";
        }
        if (q.contains("low stock") || q.contains("low on stock") || q.contains("running low") || q.contains("reorder") || q.contains("running out") || q.contains("run out")) {
            if (!Permissions.canRead(role, "product")) return denied();
            String n = db.scalar("SELECT count(*) FROM v_product WHERE low_stock AND active");
            String names = db.scalar("SELECT string_agg(name, ', ') FROM (SELECT name FROM v_product WHERE low_stock AND active ORDER BY name LIMIT 5) x");
            return "0".equals(n) ? "Nothing is below its reorder level." : n + " product" + ("1".equals(n) ? " is" : "s are") + " low on stock: " + names + (Integer.parseInt(n) > 5 ? " and more." : ".");
        }
        if (q.contains("overdue") || q.contains("late invoice")) {
            if (!dash) return denied();
            return db.scalar("SELECT fn_dashboard()->>'overdue_invoices'") + " overdue invoice(s). Total to collect is Rs. "
                    + Documents.money(Double.parseDouble(db.scalar("SELECT fn_dashboard()->>'receivable'"))) + ".";
        }
        if (q.contains("owe") || q.contains("collect") || q.contains("receivable") || q.contains("outstanding")) {
            if (!dash) return denied();
            return "Customers owe Rs. " + Documents.money(Double.parseDouble(db.scalar("SELECT fn_dashboard()->>'receivable'")))
                    + ". We owe vendors Rs. " + Documents.money(Double.parseDouble(db.scalar("SELECT fn_dashboard()->>'payable'"))) + ".";
        }
        if (q.contains("expir")) {
            if (!Permissions.canRead(role, "lot")) return denied();
            String n = db.scalar("SELECT count(*) FROM v_lot WHERE on_hand > 0 AND state IN ('expiring','expired')");
            String names = db.scalar("SELECT string_agg(product || ' lot ' || lot_no || ' (' || state || ')', ', ') FROM (SELECT * FROM v_lot WHERE on_hand > 0 AND state IN ('expiring','expired') ORDER BY expiry_date LIMIT 4) x");
            return "0".equals(n) ? "No lots are expiring soon." : n + " lot(s) expiring or expired: " + names + ".";
        }
        if (q.contains("quality") || q.contains("qc") || q.contains("inspection") || q.contains("failed check")) {
            if (!Permissions.canRead(role, "qc_inspection")) return denied();
            return db.scalar("SELECT (fn_dashboard()->>'qc_failed_30d') || ' quality check(s) failed in the last 30 days.'");
        }
        if (q.contains("sales today") || q.contains("pos") || q.contains("sold today") || q.contains("today s sales")) {
            if (!dash) return denied();
            return "Point of sale takings today: Rs. " + Documents.money(Double.parseDouble(db.scalar("SELECT fn_dashboard()->>'pos_today'"))) + ".";
        }
        if (q.contains("open") && q.contains("order")) {
            if (!dash) return denied();
            return db.scalar("SELECT (fn_dashboard()->>'open_sales_orders') || ' open sales order(s) and ' || (fn_dashboard()->>'open_purchase_orders') || ' open purchase order(s).'");
        }
        if (q.contains("stock value") || q.contains("inventory value")) {
            if (!dash) return denied();
            return "Stock is worth Rs. " + Documents.money(Double.parseDouble(db.scalar("SELECT fn_dashboard()->>'stock_value'"))) + ".";
        }
        // stock of a named product: every meaningful word must appear in the product name or SKU
        List<String> tokens = new ArrayList<>();
        for (String t : q.split(" ")) {
            if (t.length() < 2 || STOP.contains(t)) continue;
            tokens.add(t.length() > 3 && t.endsWith("s") ? t.substring(0, t.length() - 1) : t);   // cartridges -> cartridge
        }
        boolean asksStock = q.contains("stock") || q.contains("how many") || q.contains("how much") || q.contains("quantity") || q.contains("on hand");
        if (asksStock && !tokens.isEmpty() && tokens.size() <= 5) {
            if (!Permissions.canRead(role, "product")) return denied();
            StringBuilder sql = new StringBuilder("SELECT string_agg(name || ' (' || sku || '): ' || trim_scale(on_hand)::text || ' ' || COALESCE(unit, 'units'), '; ') FROM (SELECT * FROM v_product WHERE active");
            for (int i = 0; i < tokens.size(); i++) sql.append(" AND (lower(name) LIKE ? OR lower(sku) LIKE ?)");
            sql.append(" ORDER BY name LIMIT 4) x");
            String[] params = new String[tokens.size() * 2];
            for (int i = 0; i < tokens.size(); i++) { String p = "%" + tokens.get(i).replace("%", "").replace("_", "") + "%"; params[2 * i] = p; params[2 * i + 1] = p; }
            String found = db.scalar(sql.toString(), params);
            if (found != null) return "In stock: " + found + ".";
            return "I could not find a product matching " + String.join(" ", tokens) + ".";
        }
        return null;
    }

    private static String denied() { return "Your role is not allowed to see that."; }

    // ------------------------------------------------------------------ OpenJarvis (optional)

    private String askOpenJarvis(Auth.User user, String text) throws Exception {
        String snapshot = "";
        if (Permissions.canDashboard(user.role())) {
            snapshot = db.scalar("SELECT (fn_dashboard() - 'sales_7d' - 'recent_moves')::text");
        }
        String system = "You are the voice assistant inside StockMate, the stock and business system of Filtsap Filtration (water, oil and air filters). "
                + "Answer in at most two short sentences that are easy to read aloud. Use only the business data below; if the answer is not in it, say you do not have that information. "
                + "You cannot change anything in the system. Business data (JSON): " + (snapshot == null ? "none available" : snapshot);
        String body = "{\"model\":" + quote(ojModel) + ",\"stream\":false,\"messages\":[{\"role\":\"system\",\"content\":" + quote(system)
                + "},{\"role\":\"user\",\"content\":" + quote(text) + "}]}";
        String base = ojUrl.endsWith("/") ? ojUrl.substring(0, ojUrl.length() - 1) : ojUrl;
        HttpRequest.Builder rb = HttpRequest.newBuilder(URI.create(base + "/v1/chat/completions")).timeout(Duration.ofSeconds(25))
                .header("Content-Type", "application/json").POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
        if (ojKey != null && !ojKey.isBlank()) rb.header("Authorization", "Bearer " + ojKey);
        HttpResponse<String> res = http.send(rb.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (res.statusCode() / 100 != 2) throw new IllegalStateException("HTTP " + res.statusCode());
        Object choices = Json.obj(Json.parse(res.body())).get("choices");
        List<Object> list = Json.arr(choices);
        if (list.isEmpty()) return null;
        String content = Json.str(Json.obj(Json.obj(list.get(0)).get("message")).get("content")).trim();
        return content.length() > 600 ? content.substring(0, 600) : content;
    }

    private static String reply(String text, String source) {
        return "{\"reply\":" + quote(text) + ",\"source\":" + quote(source) + "}";
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
                default: if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c);
            }
        }
        return b.append('"').toString();
    }
}
