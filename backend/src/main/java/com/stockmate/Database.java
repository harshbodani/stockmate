package com.stockmate;

import java.sql.SQLException;

/** Tiny database abstraction: every call takes SQL with ? placeholders and string parameters. */
public interface Database {
    /** Runs a query and returns column 1 of row 1 as text, or null when there is no row. */
    String scalar(String sql, String... params) throws SQLException;

    /** Runs INSERT/UPDATE/DELETE and returns the number of affected rows. */
    int update(String sql, String... params) throws SQLException;
}
