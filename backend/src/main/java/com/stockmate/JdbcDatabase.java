package com.stockmate;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/** PostgreSQL access through plain JDBC with a small connection pool. Each statement is its own transaction. */
public final class JdbcDatabase implements Database {
    private final String url, user, password;
    private final BlockingQueue<Connection> pool;

    public JdbcDatabase(String url, String user, String password, int size) throws SQLException {
        this.url = url;
        this.user = user;
        this.password = password;
        this.pool = new ArrayBlockingQueue<>(size);
        for (int i = 0; i < size; i++) {
            pool.add(open()); // fails fast at start-up if the database is unreachable
        }
    }

    private Connection open() throws SQLException {
        Connection c = DriverManager.getConnection(url, user, password);
        c.setAutoCommit(true);
        try (java.sql.Statement st = c.createStatement()) {   // no query may run for more than 15 s
            st.execute("SET statement_timeout = '15s'");
            st.execute("SET idle_in_transaction_session_timeout = '30s'");
        }
        return c;
    }

    private Connection take() throws SQLException {
        try {
            Connection c = pool.poll(10, TimeUnit.SECONDS);
            if (c == null) throw new SQLException("Server is busy, please retry");
            if (!c.isValid(2)) {
                try { c.close(); } catch (SQLException ignored) { }
                c = open();
            }
            return c;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SQLException("Interrupted");
        }
    }

    private static void bind(PreparedStatement ps, String[] params) throws SQLException {
        for (int i = 0; i < params.length; i++) ps.setString(i + 1, params[i]);
    }

    @Override
    public String scalar(String sql, String... params) throws SQLException {
        Connection c = take();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, params);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        } finally {
            pool.offer(c);
        }
    }

    @Override
    public int update(String sql, String... params) throws SQLException {
        Connection c = take();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, params);
            return ps.executeUpdate();
        } finally {
            pool.offer(c);
        }
    }
}
