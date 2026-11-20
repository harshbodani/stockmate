package com.stockmate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Map;

/**
 * Lays out the printable documents (invoice, quotation, QC certificate, payslip).
 * The database supplies one JSON document per print (fn_doc_*); this class only draws it.
 */
final class Documents {
    private static final double L = 40, R = Pdf.W - 40, TOP = 40, BOTTOM = Pdf.H - 50;

    private Documents() { }

    static byte[] build(String type, String json) {
        Map<String, Object> d = Json.obj(Json.parse(json));
        switch (type) {
            case "invoice": return invoice(d);
            case "quotation": return quotation(d);
            case "qc": return qc(d);
            case "payslip": return payslip(d);
            default: throw new IllegalArgumentException("Unknown document type");
        }
    }

    // ------------------------------------------------------------------ helpers

    /** Drawing cursor that starts new pages with the company header and numbers them at the end. */
    private static final class Sheet {
        final Pdf pdf = new Pdf();
        final Map<String, Object> company;
        final String title;
        double y;

        Sheet(Map<String, Object> company, String title) {
            this.company = company; this.title = title;
            header();
        }

        void header() {
            pdf.text(L, 60, Json.str(company.get("name")), 20, true);
            double yy = 76;
            for (String ln : Pdf.wrap(Json.str(company.get("address")), 300, 9, false)) { pdf.text(L, yy, ln, 9, false); yy += 11; }
            String contact = join("  |  ", opt("GSTIN: ", company.get("gstin")), opt("Ph: ", company.get("phone")), opt("", company.get("email")));
            if (!contact.isEmpty()) { pdf.text(L, yy, contact, 9, false); yy += 11; }
            pdf.text(R, 60, title, 16, true, 'r');
            pdf.line(L, yy + 4, R, yy + 4, 1);
            y = yy + 22;
        }

        void ensure(double need) {
            if (y + need > BOTTOM) { pdf.newPage(); header(); }
        }

        byte[] finish() {
            return pdf.toBytes();
        }
    }

    private static String opt(String label, Object v) { String s = Json.str(v).trim(); return s.isEmpty() ? "" : label + s; }

    private static String join(String sep, String... parts) {
        StringBuilder b = new StringBuilder();
        for (String p : parts) if (!p.isEmpty()) b.append(b.length() > 0 ? sep : "").append(p);
        return b.toString();
    }

    /** 1234567.5 -> 12,34,567.50 (Indian digit grouping). */
    static String money(double v) {
        BigDecimal bd = BigDecimal.valueOf(v).setScale(2, RoundingMode.HALF_UP);
        String[] parts = bd.abs().toPlainString().split("\\.");
        String ip = parts[0];
        String grouped;
        if (ip.length() <= 3) grouped = ip;
        else {
            String last3 = ip.substring(ip.length() - 3), rest = ip.substring(0, ip.length() - 3);
            StringBuilder b = new StringBuilder();
            for (int i = 0; i < rest.length(); i++) {
                if (i > 0 && (rest.length() - i) % 2 == 0) b.append(',');
                b.append(rest.charAt(i));
            }
            grouped = b + "," + last3;
        }
        return (bd.signum() < 0 ? "-" : "") + grouped + "." + parts[1];
    }

    static String qty(double v) { return v == Math.rint(v) ? String.valueOf((long) v) : new BigDecimal(v).setScale(3, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString(); }

    private static final String[] ONES = {"", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven",
        "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"};
    private static final String[] TENS = {"", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"};

    private static String below100(int n) { return n < 20 ? ONES[n] : TENS[n / 10] + (n % 10 > 0 ? " " + ONES[n % 10] : ""); }

    private static String below1000(int n) {
        String s = n >= 100 ? ONES[n / 100] + " Hundred" : "";
        if (n % 100 > 0) s += (s.isEmpty() ? "" : " ") + below100(n % 100);
        return s;
    }

    /** Amount in words using lakh and crore, e.g. "Rupees Fifty Four Thousand Five Hundred Fifty One Only". */
    static String inWords(double amount) {
        long total = Math.round(Math.abs(amount) * 100);
        long rupees = total / 100; int paise = (int) (total % 100);
        String w = rupees == 0 ? "Zero" : "";
        long crore = rupees / 10_000_000; rupees %= 10_000_000;
        long lakh = rupees / 100_000; rupees %= 100_000;
        long thousand = rupees / 1000; rupees %= 1000;
        StringBuilder b = new StringBuilder(w);
        if (crore > 0) b.append(below1000((int) crore)).append(" Crore ");
        if (lakh > 0) b.append(below100((int) lakh)).append(" Lakh ");
        if (thousand > 0) b.append(below100((int) thousand)).append(" Thousand ");
        if (rupees > 0) b.append(below1000((int) rupees));
        String out = "Rupees " + b.toString().trim();
        if (paise > 0) out += " and " + below100(paise) + " Paise";
        return out + " Only";
    }

    private static void label(Pdf p, double x, double y, String k, String v) {
        p.text(x, y, k, 8, false);
        p.text(x, y + 11, v.isEmpty() ? "-" : v, 10, true);
    }

    private static String date(Object v) {
        String s = Json.str(v);
        if (s.length() < 10) return s;
        String[] m = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
        try { return s.substring(8, 10) + " " + m[Integer.parseInt(s.substring(5, 7)) - 1] + " " + s.substring(0, 4); }
        catch (RuntimeException e) { return s; }
    }

    /** Party block: heading, name, address, GSTIN, state. Returns the y after it. */
    private static double party(Sheet s, double x, double y, double w, String heading, Map<String, Object> p) {
        s.pdf.text(x, y, heading, 8, false);
        s.pdf.text(x, y + 13, Json.str(p.get("name")), 11, true);
        double yy = y + 26;
        for (String ln : Pdf.wrap(Json.str(p.get("address")), w, 9, false)) { s.pdf.text(x, yy, ln, 9, false); yy += 11; }
        String g = join("   ", opt("GSTIN: ", p.get("gstin")), opt("State code: ", p.get("state_code")));
        if (!g.isEmpty()) { s.pdf.text(x, yy, g, 9, false); yy += 11; }
        return yy;
    }

    private static void tableHeader(Sheet s, double[] edges, String[] heads, char[] align) {
        s.pdf.rect(L, s.y - 11, R - L, 17, 0.9);
        for (int i = 0; i < heads.length; i++) {
            double x = align[i] == 'r' ? edges[i + 1] - 4 : edges[i] + 4;
            s.pdf.text(x, s.y, heads[i], 8, true, align[i]);
        }
        s.y += 12;
    }

    private static void totalRow(Sheet s, String k, double v, boolean bold) {
        s.ensure(16);
        s.pdf.text(R - 150, s.y, k, bold ? 11 : 10, bold);
        s.pdf.text(R, s.y, money(v), bold ? 11 : 10, bold, 'r');
        s.y += bold ? 18 : 14;
    }

    private static void notes(Sheet s, String heading, String body) {
        if (body.isBlank()) return;
        s.ensure(40);
        s.pdf.text(L, s.y, heading, 9, true); s.y += 12;
        for (String ln : Pdf.wrap(body, R - L, 9, false)) { s.ensure(12); s.pdf.text(L, s.y, ln, 9, false); s.y += 11; }
        s.y += 6;
    }

    private static void signature(Sheet s) {
        s.ensure(70);
        s.y += 20;
        s.pdf.text(R, s.y, "For " + Json.str(s.company.get("name")), 10, true, 'r');
        s.y += 40;
        s.pdf.line(R - 150, s.y, R, s.y, 0.6);
        s.pdf.text(R, s.y + 12, "Authorised signatory", 8, false, 'r');
        s.y += 20;
    }

    // ------------------------------------------------------------------ invoice

    private static byte[] invoice(Map<String, Object> d) {
        Map<String, Object> inv = Json.obj(d.get("invoice")), partner = Json.obj(d.get("partner")), company = Json.obj(d.get("company"));
        boolean sales = "customer".equals(Json.str(inv.get("kind")));
        boolean inter = "inter".equals(Json.str(inv.get("supply_type")));
        Sheet s = new Sheet(company, sales ? "TAX INVOICE" : "VENDOR BILL");

        label(s.pdf, L, s.y, "Invoice no.", Json.str(inv.get("number")));
        label(s.pdf, L + 150, s.y, "Date", date(inv.get("issue_date")));
        label(s.pdf, L + 270, s.y, "Due date", date(inv.get("due_date")));
        label(s.pdf, L + 390, s.y, "Order ref.", Json.str(d.get("order_ref")));
        s.y += 32;
        label(s.pdf, L, s.y, "Supply", inter ? "Inter-state (IGST)" : "Within state (CGST + SGST)");
        label(s.pdf, L + 150, s.y, "Place of supply (state code)", Json.str(inv.get("place_of_supply")));
        s.y += 34;
        s.pdf.line(L, s.y - 12, R, s.y - 12, 0.5);
        s.y = party(s, L, s.y, 300, sales ? "BILL TO" : "BILLED BY (VENDOR)", partner) + 12;

        double[] e = {L, L + 20, L + 190, L + 226, L + 258, L + 313, L + 347, L + 409, L + 443, R};
        String[] heads = {"#", "Description", "HSN", "Qty", "Rate", "Disc %", "Taxable", "GST %", "Amount"};
        char[] al = {'l', 'l', 'l', 'r', 'r', 'r', 'r', 'r', 'r'};
        tableHeader(s, e, heads, al);
        int n = 0;
        for (Object o : Json.arr(d.get("lines"))) {
            Map<String, Object> l = Json.obj(o);
            List<String> desc = Pdf.wrap(Json.str(l.get("description")), e[2] - e[1] - 8, 9, false);
            s.ensure(12 * desc.size() + 6);
            if (s.y + 12 * desc.size() > BOTTOM) { s.pdf.newPage(); s.header(); tableHeader(s, e, heads, al); }
            n++;
            String[] cells = {String.valueOf(n), "", Json.str(l.get("hsn_code")), qty(Json.num(l.get("qty"))), money(Json.num(l.get("unit_price"))),
                qty(Json.num(l.get("discount_pct"))), money(Json.num(l.get("taxable_value"))), qty(Json.num(l.get("gst_rate"))), money(Json.num(l.get("line_total")))};
            for (int i = 0; i < cells.length; i++) {
                if (i == 1) continue;
                s.pdf.text(al[i] == 'r' ? e[i + 1] - 4 : e[i] + 4, s.y, cells[i], 9, false, al[i]);
            }
            for (String ln : desc) { s.pdf.text(e[1] + 4, s.y, ln, 9, false); s.y += 12; }
            s.pdf.line(L, s.y - 8, R, s.y - 8, 0.3);
        }
        s.y += 10;
        double sub = Json.num(inv.get("subtotal")), ro = Json.num(inv.get("round_off")), total = Json.num(inv.get("total"));
        totalRow(s, "Taxable value", sub, false);
        if (inter) totalRow(s, "IGST", Json.num(inv.get("igst")), false);
        else { totalRow(s, "CGST", Json.num(inv.get("cgst")), false); totalRow(s, "SGST", Json.num(inv.get("sgst")), false); }
        if (Math.abs(ro) > 0.0001) totalRow(s, "Round off", ro, false);
        s.pdf.line(R - 150, s.y - 10, R, s.y - 10, 0.6);
        s.y += 4;
        totalRow(s, "Total (Rs.)", total, true);
        s.ensure(30);
        s.pdf.text(L, s.y, inWords(total), 9, true); s.y += 14;
        double paid = Json.num(inv.get("paid"));
        if (paid > 0) { s.pdf.text(L, s.y, "Paid so far: Rs. " + money(paid) + "     Balance due: Rs. " + money(Json.num(inv.get("balance"))), 9, false); s.y += 14; }
        s.y += 6;
        if (sales) {
            notes(s, "Bank details", Json.str(company.get("bank_details")));
            notes(s, "Terms", Json.str(company.get("invoice_terms")));
        }
        signature(s);
        return s.finish();
    }

    // ------------------------------------------------------------------ quotation

    private static byte[] quotation(Map<String, Object> d) {
        Map<String, Object> q = Json.obj(d.get("quotation")), partner = Json.obj(d.get("partner")), company = Json.obj(d.get("company"));
        boolean intra = !Boolean.FALSE.equals(d.get("intra"));
        Sheet s = new Sheet(company, "QUOTATION");
        label(s.pdf, L, s.y, "Quotation no.", Json.str(q.get("number")));
        label(s.pdf, L + 150, s.y, "Date", date(q.get("quote_date")));
        label(s.pdf, L + 270, s.y, "Valid until", date(q.get("valid_until")));
        label(s.pdf, L + 390, s.y, "Status", Json.str(q.get("status")).toUpperCase());
        s.y += 34;
        s.pdf.line(L, s.y - 12, R, s.y - 12, 0.5);
        s.y = party(s, L, s.y, 300, "PREPARED FOR", partner) + 12;

        double[] e = {L, L + 20, L + 235, L + 275, L + 315, L + 375, L + 415, L + 485, R};
        String[] heads = {"#", "Item", "HSN", "Qty", "Rate", "Disc %", "Taxable", "GST %"};
        char[] al = {'l', 'l', 'l', 'r', 'r', 'r', 'r', 'r'};
        tableHeader(s, e, heads, al);
        int n = 0;
        for (Object o : Json.arr(d.get("lines"))) {
            Map<String, Object> l = Json.obj(o);
            List<String> desc = Pdf.wrap(Json.str(l.get("name")), e[2] - e[1] - 8, 9, false);
            if (s.y + 12 * desc.size() > BOTTOM) { s.pdf.newPage(); s.header(); tableHeader(s, e, heads, al); }
            n++;
            double taxable = Json.num(l.get("taxable")), rate = Json.num(l.get("gst_rate"));
            String[] cells = {String.valueOf(n), "", Json.str(l.get("hsn_code")), qty(Json.num(l.get("qty"))), money(Json.num(l.get("unit_price"))),
                qty(Json.num(l.get("discount_pct"))), money(taxable), qty(rate)};
            for (int i = 0; i < cells.length; i++) {
                if (i == 1) continue;
                s.pdf.text(al[i] == 'r' ? e[i + 1] - 4 : e[i] + 4, s.y, cells[i], 9, false, al[i]);
            }
            for (String ln : desc) { s.pdf.text(e[1] + 4, s.y, ln, 9, false); s.y += 12; }
            s.pdf.line(L, s.y - 8, R, s.y - 8, 0.3);
        }
        s.y += 10;
        totalRow(s, "Total before GST", Json.num(q.get("total")), false);
        totalRow(s, intra ? "GST (CGST + SGST)" : "GST (IGST)", Json.num(q.get("tax")), false);
        s.pdf.line(R - 150, s.y - 10, R, s.y - 10, 0.6);
        s.y += 4;
        totalRow(s, "Grand total (Rs.)", Json.num(q.get("grand_total")), true);
        s.ensure(20);
        s.pdf.text(L, s.y, inWords(Json.num(q.get("grand_total"))), 9, true); s.y += 18;
        notes(s, "Notes", Json.str(q.get("notes")));
        notes(s, "Terms", Json.str(q.get("terms")));
        signature(s);
        return s.finish();
    }

    // ------------------------------------------------------------------ QC certificate

    private static byte[] qc(Map<String, Object> d) {
        Map<String, Object> q = Json.obj(d.get("inspection")), product = Json.obj(d.get("product")), lot = Json.obj(d.get("lot")), company = Json.obj(d.get("company"));
        Sheet s = new Sheet(company, "QC REPORT");
        String status = Json.str(q.get("status")).toUpperCase();
        label(s.pdf, L, s.y, "Inspection no.", Json.str(q.get("number")));
        label(s.pdf, L + 150, s.y, "Type", Json.str(q.get("kind")).replace('_', ' '));
        label(s.pdf, L + 270, s.y, "Date", date(q.get("inspected_on")));
        label(s.pdf, L + 390, s.y, "Result", status);
        s.y += 34;
        label(s.pdf, L, s.y, "Product", join(" - ", Json.str(product.get("sku")), Json.str(product.get("name"))));
        label(s.pdf, L + 270, s.y, "Lot no.", Json.str(q.get("lot_no")));
        label(s.pdf, L + 390, s.y, "Expiry", date(lot.get("expiry_date")));
        s.y += 34;
        label(s.pdf, L, s.y, "Inspector", Json.str(d.get("inspector")));
        label(s.pdf, L + 150, s.y, "Sample size", qty(Json.num(q.get("sample_size"))));
        label(s.pdf, L + 270, s.y, "Source", join(" ", Json.str(d.get("purchase_order")), Json.str(d.get("production_order"))));
        s.y += 34;
        s.pdf.line(L, s.y - 12, R, s.y - 12, 0.5);

        double[] e = {L, L + 190, L + 250, L + 310, L + 370, L + 440, R};
        String[] heads = {"Parameter", "Unit", "Min", "Max", "Measured", "Result"};
        char[] al = {'l', 'l', 'r', 'r', 'r', 'l'};
        tableHeader(s, e, heads, al);
        for (Object o : Json.arr(d.get("results"))) {
            Map<String, Object> r = Json.obj(o);
            s.ensure(18);
            boolean ok = Boolean.TRUE.equals(r.get("passed"));
            String[] cells = {Json.str(r.get("parameter")), Json.str(r.get("unit")), r.get("spec_min") == null ? "-" : qty(Json.num(r.get("spec_min"))),
                r.get("spec_max") == null ? "-" : qty(Json.num(r.get("spec_max"))), qty(Json.num(r.get("measured"))), ok ? "PASS" : "FAIL"};
            for (int i = 0; i < cells.length; i++) {
                s.pdf.text(al[i] == 'r' ? e[i + 1] - 4 : e[i] + 4, s.y, cells[i], 9, i == 5 && !ok, al[i]);
            }
            s.y += 14;
            s.pdf.line(L, s.y - 9, R, s.y - 9, 0.3);
        }
        s.y += 12;
        if (!Json.str(q.get("disposition")).isEmpty()) {
            s.pdf.text(L, s.y, "Decision: " + Json.str(q.get("disposition")).replace('_', ' ').toUpperCase(), 11, true);
            s.y += 18;
        }
        notes(s, "Reason for rejection", Json.str(q.get("rejection_reason")));
        notes(s, "Notes", Json.str(q.get("notes")));
        s.pdf.text(L, s.y + 4, "Readings are checked against the minimum and maximum above; one reading outside its range fails the inspection.", 8, false);
        s.y += 16;
        signature(s);
        return s.finish();
    }

    // ------------------------------------------------------------------ payslip

    private static byte[] payslip(Map<String, Object> d) {
        Map<String, Object> p = Json.obj(d.get("payslip")), emp = Json.obj(d.get("employee")), company = Json.obj(d.get("company"));
        Sheet s = new Sheet(company, "PAYSLIP");
        label(s.pdf, L, s.y, "Employee", Json.str(emp.get("name")));
        label(s.pdf, L + 220, s.y, "Job title", Json.str(emp.get("job_title")));
        label(s.pdf, L + 390, s.y, "Joined", date(emp.get("hire_date")));
        s.y += 34;
        label(s.pdf, L, s.y, "Pay period", date(p.get("period_start")) + " to " + date(p.get("period_end")));
        label(s.pdf, L + 220, s.y, "Hours worked", qty(Json.num(p.get("hours"))));
        label(s.pdf, L + 390, s.y, "Hourly rate (Rs.)", money(Json.num(emp.get("hourly_rate"))));
        s.y += 40;
        s.pdf.line(L, s.y - 14, R, s.y - 14, 0.5);
        totalRow(s, "Gross pay", Json.num(p.get("gross")), false);
        totalRow(s, "Deductions", Json.num(p.get("deductions")), false);
        s.pdf.line(R - 150, s.y - 10, R, s.y - 10, 0.6);
        s.y += 4;
        totalRow(s, "Net pay (Rs.)", Json.num(p.get("net")), true);
        s.pdf.text(L, s.y, inWords(Json.num(p.get("net"))), 9, true);
        s.y += 20;
        signature(s);
        return s.finish();
    }
}
