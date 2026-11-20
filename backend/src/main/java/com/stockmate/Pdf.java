package com.stockmate;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * A very small PDF writer: A4 pages, the two standard Helvetica fonts, text, lines and filled rectangles.
 * No fonts are embedded, so only Latin text is supported (the rupee sign is written as "Rs.").
 * Origin is the top-left corner and units are points, which makes layout code read top to bottom.
 */
final class Pdf {
    static final double W = 595.28, H = 841.89;
    private static final int[] REG = {278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584};
    private static final int[] BOLD = {278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584};

    private final List<StringBuilder> pages = new ArrayList<>();
    private StringBuilder cur;

    Pdf() { newPage(); }

    void newPage() { cur = new StringBuilder(); pages.add(cur); }

    int pageCount() { return pages.size(); }

    /** Replace characters the standard fonts cannot show; keep Latin-1. */
    static String clean(String t) {
        StringBuilder b = new StringBuilder();
        for (char c : (t == null ? "" : t).toCharArray()) {
            if (c == '₹') b.append("Rs. ");
            else if (c == '–' || c == '—') b.append('-');
            else if (c == '‘' || c == '’') b.append('\'');
            else if (c == '“' || c == '”') b.append('"');
            else if (c == '\n' || c == '\r' || c == '\t') b.append(' ');
            else if (c >= 32 && c < 127 || c >= 160 && c <= 255) b.append(c);
            else b.append('?');
        }
        return b.toString();
    }

    static double width(String t, boolean bold, double size) {
        int[] w = bold ? BOLD : REG;
        double sum = 0;
        for (char c : clean(t).toCharArray()) sum += c >= 32 && c < 127 ? w[c - 32] : 556;
        return sum * size / 1000.0;
    }

    private static String num(double d) { return String.format(java.util.Locale.ROOT, "%.2f", d); }

    private static String esc(String t) {
        return clean(t).replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)");
    }

    /** Text with its baseline at y (from the top). align: 'l', 'r' (x is the right edge) or 'c'. */
    void text(double x, double y, String t, double size, boolean bold, char align) {
        double w = width(t, bold, size);
        double px = align == 'r' ? x - w : align == 'c' ? x - w / 2 : x;
        cur.append("BT /").append(bold ? "F2" : "F1").append(' ').append(num(size)).append(" Tf ")
           .append(num(px)).append(' ').append(num(H - y)).append(" Td (").append(esc(t)).append(") Tj ET\n");
    }

    void text(double x, double y, String t, double size, boolean bold) { text(x, y, t, size, bold, 'l'); }

    void line(double x1, double y1, double x2, double y2, double weight) {
        cur.append(num(weight)).append(" w ").append(num(x1)).append(' ').append(num(H - y1)).append(" m ")
           .append(num(x2)).append(' ').append(num(H - y2)).append(" l S\n");
    }

    void rect(double x, double y, double w, double h, double gray) {
        cur.append(num(gray)).append(" g ").append(num(x)).append(' ').append(num(H - y - h)).append(' ')
           .append(num(w)).append(' ').append(num(h)).append(" re f 0 g\n");
    }

    void box(double x, double y, double w, double h, double weight) {
        cur.append(num(weight)).append(" w ").append(num(x)).append(' ').append(num(H - y - h)).append(' ')
           .append(num(w)).append(' ').append(num(h)).append(" re S\n");
    }

    /** Break text into lines no wider than maxW. */
    static List<String> wrap(String t, double maxW, double size, boolean bold) {
        List<String> out = new ArrayList<>();
        for (String para : (t == null ? "" : t).split("\\r?\\n")) {
            StringBuilder line = new StringBuilder();
            for (String word : para.trim().split("\\s+")) {
                if (word.isEmpty()) continue;
                String test = line.length() == 0 ? word : line + " " + word;
                if (width(test, bold, size) <= maxW || line.length() == 0) line = new StringBuilder(test);
                else { out.add(line.toString()); line = new StringBuilder(word); }
            }
            if (line.length() > 0) out.add(line.toString());
        }
        return out;
    }

    byte[] toBytes() {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        List<Integer> offsets = new ArrayList<>();
        int n = pages.size();
        // objects: 1 catalog, 2 pages, 3 F1, 4 F2, then page/content pairs
        List<String> objs = new ArrayList<>();
        objs.add("<< /Type /Catalog /Pages 2 0 R >>");
        StringBuilder kids = new StringBuilder();
        for (int p = 0; p < n; p++) kids.append(5 + 2 * p).append(" 0 R ");
        objs.add("<< /Type /Pages /Kids [" + kids + "] /Count " + n + " >>");
        objs.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        objs.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
        for (int p = 0; p < n; p++) {
            objs.add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents " + (6 + 2 * p) + " 0 R >>");
            objs.add(null); // content stream, written below
        }
        write(out, "%PDF-1.4\n");
        for (int k = 0; k < objs.size(); k++) {
            offsets.add(out.size());
            write(out, (k + 1) + " 0 obj\n");
            if (objs.get(k) != null) {
                write(out, objs.get(k) + "\n");
            } else {
                byte[] body = pages.get((k - 5) / 2).toString().getBytes(StandardCharsets.ISO_8859_1);
                write(out, "<< /Length " + body.length + " >>\nstream\n");
                out.writeBytes(body);
                write(out, "\nendstream\n");
            }
            write(out, "endobj\n");
        }
        int xref = out.size();
        write(out, "xref\n0 " + (objs.size() + 1) + "\n0000000000 65535 f \n");
        for (int off : offsets) write(out, String.format("%010d 00000 n \n", off));
        write(out, "trailer\n<< /Size " + (objs.size() + 1) + " /Root 1 0 R >>\nstartxref\n" + xref + "\n%%EOF\n");
        return out.toByteArray();
    }

    private static void write(ByteArrayOutputStream o, String s) { o.writeBytes(s.getBytes(StandardCharsets.ISO_8859_1)); }
}
