package com.stockmate;

import com.sun.net.httpserver.HttpServer;

import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.Executors;

/**
 * StockMate server entry point.
 * Settings come from environment variables (defaults in brackets):
 *   PORT [8080]  DB_URL [jdbc:postgresql://localhost:5432/stockmate]  DB_USER [postgres]  DB_PASS []
 *   FRONTEND_DIR [./frontend or ../frontend]
 */
public final class Main {
    static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    /** Reminders about unsafe settings; the server still starts so a local demo is easy. */
    private static void warnings(String host) {
        if (env("DB_USER", "postgres").equals("postgres")) System.err.println("WARNING: connecting as the database superuser. Create the limited account in db/app_role.sql and set DB_USER/DB_PASS.");
        if (env("DB_PASS", "").isEmpty()) System.err.println("WARNING: DB_PASS is empty.");
        boolean exposed = !(host.equals("127.0.0.1") || host.equals("localhost") || host.equals("::1"));
        if (exposed && !"true".equalsIgnoreCase(env("COOKIE_SECURE", "false"))) {
            System.err.println("WARNING: listening beyond this computer without COOKIE_SECURE=true. Put an HTTPS reverse proxy in front and set COOKIE_SECURE=true.");
        }
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        String host = env("HOST", "127.0.0.1");   // local only by default; set HOST=0.0.0.0 (behind HTTPS) to serve other computers
        // limits against slow or flooding clients
        System.setProperty("sun.net.httpserver.maxReqTime", "30");
        System.setProperty("sun.net.httpserver.maxRspTime", "60");
        System.setProperty("sun.net.httpserver.maxReqHeaders", "60");
        System.setProperty("sun.net.httpserver.maxIdleConnections", "100");
        warnings(host);
        Database db = new JdbcDatabase(
                env("DB_URL", "jdbc:postgresql://localhost:5432/stockmate"),
                env("DB_USER", "postgres"),
                env("DB_PASS", ""),
                8);

        Path web = Path.of(env("FRONTEND_DIR", Files.isDirectory(Path.of("frontend")) ? "frontend" : "../frontend"))
                .toAbsolutePath().normalize();
        if (!Files.isDirectory(web)) throw new IllegalStateException("Frontend folder not found: " + web);

        HttpServer server = HttpServer.create(new InetSocketAddress(host, port), 0);
        server.createContext("/", new Api(db, web));
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("StockMate running at http://" + host + ":" + port + "  (frontend: " + web + ")");
    }
}
