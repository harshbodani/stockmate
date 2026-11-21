package com.stockmate;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Minimal JSON reader: objects become Map, arrays List, numbers BigDecimal-as-String is avoided (Double/Long), null stays null. */
final class Json {
    private final String s;
    private int i;
    private int depth;
    private static final int MAX_DEPTH = 40;

    private Json(String s) { this.s = s; }

    static Object parse(String text) {
        try {
            Json j = new Json(text);
            j.ws();
            Object v = j.value();
            j.ws();
            if (j.i != text.length()) throw new IllegalArgumentException("Unexpected text after JSON value");
            return v;
        } catch (IllegalArgumentException e) {
            throw e;
        } catch (RuntimeException e) {
            throw new IllegalArgumentException("Invalid JSON");
        }
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> obj(Object o) { return o instanceof Map ? (Map<String, Object>) o : Map.of(); }

    @SuppressWarnings("unchecked")
    static List<Object> arr(Object o) { return o instanceof List ? (List<Object>) o : List.of(); }

    static String str(Object o) { return o == null ? "" : o instanceof Double d && d == Math.rint(d) && Math.abs(d) < 1e15 ? String.valueOf(d.longValue()) : String.valueOf(o); }

    static double num(Object o) {
        if (o instanceof Number n) return n.doubleValue();
        try { return o == null ? 0 : Double.parseDouble(o.toString()); } catch (NumberFormatException e) { return 0; }
    }

    private void ws() { while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++; }

    private Object value() {
        if (i >= s.length()) throw new IllegalArgumentException("Unexpected end of JSON");
        char c = s.charAt(i);
        if ((c == '{' || c == '[') && ++depth > MAX_DEPTH) throw new IllegalArgumentException("JSON is nested too deeply");
        if (c == '{') {
            Map<String, Object> m = new LinkedHashMap<>();
            i++; ws();
            if (s.charAt(i) == '}') { i++; depth--; return m; }
            while (true) {
                ws(); String k = string(); ws(); expect(':'); ws();
                m.put(k, value()); ws();
                if (s.charAt(i) == ',') { i++; continue; }
                expect('}'); depth--; return m;
            }
        }
        if (c == '[') {
            List<Object> l = new ArrayList<>();
            i++; ws();
            if (s.charAt(i) == ']') { i++; depth--; return l; }
            while (true) {
                ws(); l.add(value()); ws();
                if (s.charAt(i) == ',') { i++; continue; }
                expect(']'); depth--; return l;
            }
        }
        if (c == '"') return string();
        if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
        if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
        if (s.startsWith("null", i)) { i += 4; return null; }
        int st = i;
        while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
        if (st == i) throw new IllegalArgumentException("Bad JSON at position " + i);
        return Double.parseDouble(s.substring(st, i));
    }

    private void expect(char c) {
        if (i >= s.length() || s.charAt(i) != c) throw new IllegalArgumentException("Expected '" + c + "' at position " + i);
        i++;
    }

    private String string() {
        expect('"');
        StringBuilder b = new StringBuilder();
        while (true) {
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c != '\\') { b.append(c); continue; }
            char e = s.charAt(i++);
            switch (e) {
                case 'n': b.append('\n'); break;
                case 't': b.append('\t'); break;
                case 'r': b.append('\r'); break;
                case 'b': b.append('\b'); break;
                case 'f': b.append('\f'); break;
                case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
                default: b.append(e);
            }
        }
    }
}
