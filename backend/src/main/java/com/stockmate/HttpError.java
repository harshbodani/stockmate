package com.stockmate;

/** A problem with the request itself (not a server fault): carries the HTTP status to send back. */
final class HttpError extends Exception {
    private static final long serialVersionUID = 1L;
    final int status;

    HttpError(int status, String message) {
        super(message);
        this.status = status;
    }
}
