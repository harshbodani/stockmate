package com.stockmate;

import java.util.Map;
import java.util.Set;

/**
 * Who may do what. One place to read and change the rules.
 *   admin    everything
 *   sales    CRM, customers, sales orders
 *   store    products, stock, purchasing, manufacturing, deliveries
 *   accounts invoices and payments
 *   hr       employees and payslips
 *   cashier  POS terminal only
 *   viewer   read-only
 * Company settings (GSTIN, address) can only be changed by an admin.
 * Sales also see QC and lots (read); store also see quotations (read).
 * Projects, tasks and timesheets can be edited by everyone except cashier and viewer.
 */
final class Permissions {
    private record Rules(Set<String> write, Set<String> rpc) { }

    /** The cashier only sees what the POS terminal needs. */
    private static final Set<String> CASHIER_READ = Set.of("product", "stock", "cash_register", "pos_sale", "pos_sale_line");

    private static final Set<String> TEAM_WRITE = Set.of("project", "task", "timesheet");
    private static final Set<String> TEAM_ROLES = Set.of("sales", "store", "accounts", "hr");

    private static final Map<String, Rules> ROLES = Map.of(
            "sales", new Rules(
                    Set.of("partner", "crm_lead", "crm_activity", "sales_order", "sales_order_line", "quotation", "quotation_line"),
                    Set.of("fn_qt_send", "fn_qt_accept", "fn_qt_reject", "fn_qt_reopen", "fn_qt_convert", "fn_crm_convert", "fn_so_confirm", "fn_so_cancel", "fn_pos_checkout")),
            "store", new Rules(
                    Set.of("product", "warehouse", "purchase_order", "purchase_order_line", "bom", "bom_line",
                            "work_center", "production_order", "work_order", "qc_inspection", "qc_result"),
                    Set.of("fn_adjust_stock", "fn_transfer_stock", "fn_reorder_create_pos", "fn_po_confirm", "fn_po_receive",
                            "fn_po_cancel", "fn_mo_start", "fn_mo_complete", "fn_mo_cancel", "fn_qc_complete", "fn_so_deliver", "fn_pos_checkout")),
            "accounts", new Rules(Set.of("payment", "partner"), Set.of("fn_create_invoice")),
            "hr", new Rules(Set.of("employee"), Set.of("fn_generate_payslip")),
            "cashier", new Rules(Set.of(), Set.of("fn_pos_checkout")),
            "viewer", new Rules(Set.of(), Set.of()));

    private Permissions() { }

    static boolean canRead(String role, String entity) {
        if (role.equals("admin")) return true;
        if (role.equals("cashier")) return CASHIER_READ.contains(entity);
        switch (entity) {
            case "app_user":
            case "audit_log":
                return false;
            case "employee":
            case "payslip":
                return role.equals("hr");
            default:
                return ROLES.containsKey(role);
        }
    }

    /** The dashboard shows company-wide finance figures, so the cashier does not get it. */
    static boolean canDashboard(String role) {
        return !role.equals("cashier");
    }

    static boolean canWrite(String role, String entity) {
        if (role.equals("admin")) return true;
        Rules r = ROLES.get(role);
        if (r == null) return false;
        return r.write().contains(entity) || (TEAM_ROLES.contains(role) && TEAM_WRITE.contains(entity));
    }

    static boolean canRpc(String role, String fn) {
        if (role.equals("admin")) return true;
        Rules r = ROLES.get(role);
        return r != null && r.rpc().contains(fn);
    }
}
