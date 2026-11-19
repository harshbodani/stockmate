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

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PORT", "8080"));
        Database db = new JdbcDatabase(
                env("DB_URL", "jdbc:postgresql://localhost:5432/stockmate"),
                env("DB_USER", "postgres"),
                env("DB_PASS", ""),
                8);

        Path web = Path.of(env("FRONTEND_DIR", Files.isDirectory(Path.of("frontend")) ? "frontend" : "../frontend"))
                .toAbsolutePath().normalize();
        if (!Files.isDirectory(web)) throw new IllegalStateException("Frontend folder not found: " + web);

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/", new Api(db, web));
        server.setExecutor(Executors.newFixedThreadPool(8));
        server.start();
        System.out.println("StockMate running at http://localhost:" + port + "  (frontend: " + web + ")");
    }
}
