-- StockMate: business logic in PL/pgSQL.
-- Every "action" function takes one jsonb argument and returns jsonb,
-- so the Java backend can call them all the same way: SELECT fn_xxx(?::jsonb)

-- ---------- Stock core ----------
-- Raw movement: updates totals, lot quantities and the movement log. Callers decide which lot.
CREATE OR REPLACE FUNCTION fn_move_raw(p_product int, p_wh int, p_qty numeric, p_reason text,
                                       p_ref_type text, p_ref_id int, p_lot int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE have numeric;
BEGIN
  IF p_qty = 0 THEN RETURN; END IF;
  IF p_qty < 0 THEN
    SELECT COALESCE(qty, 0) INTO have FROM stock_quant WHERE product_id = p_product AND warehouse_id = p_wh;
    have := COALESCE(have, 0);
    IF have + p_qty < 0 THEN
      RAISE EXCEPTION 'Insufficient stock for "%": need %, have % in this warehouse',
        (SELECT name FROM product WHERE id = p_product), -p_qty, have;
    END IF;
  END IF;
  UPDATE stock_quant SET qty = qty + p_qty WHERE product_id = p_product AND warehouse_id = p_wh;
  IF NOT FOUND THEN
    INSERT INTO stock_quant (product_id, warehouse_id, qty) VALUES (p_product, p_wh, p_qty);
  END IF;
  IF p_lot IS NOT NULL THEN
    UPDATE lot_quant SET qty = qty + p_qty WHERE lot_id = p_lot AND warehouse_id = p_wh;
    IF NOT FOUND THEN
      INSERT INTO lot_quant (lot_id, warehouse_id, qty) VALUES (p_lot, p_wh, p_qty);
    END IF;
  END IF;
  INSERT INTO stock_move (product_id, warehouse_id, lot_id, qty, reason, ref_type, ref_id)
  VALUES (p_product, p_wh, p_lot, p_qty, p_reason, p_ref_type, p_ref_id);
END $$;

-- Which lots to take stock from: earliest expiry first, then oldest received (FEFO / FIFO).
-- Rejected and expired lots are never used.
CREATE OR REPLACE FUNCTION fn_alloc_lots(p_product int, p_wh int, p_need numeric)
RETURNS TABLE (alloc_lot int, alloc_qty numeric) LANGUAGE plpgsql AS $$
DECLARE r record; remaining numeric := p_need; take numeric;
BEGIN
  FOR r IN SELECT lq.lot_id AS lid, lq.qty AS q
             FROM lot_quant lq JOIN lot l ON l.id = lq.lot_id
            WHERE l.product_id = p_product AND lq.warehouse_id = p_wh AND lq.qty > 0
              AND l.quality_status = 'ok' AND (l.expiry_date IS NULL OR l.expiry_date >= current_date)
            ORDER BY l.expiry_date NULLS LAST, l.received_date, l.id
              FOR UPDATE OF lq LOOP
    take := LEAST(r.q, remaining);
    alloc_lot := r.lid; alloc_qty := take;
    RETURN NEXT;
    remaining := remaining - take;
    EXIT WHEN remaining <= 0;
  END LOOP;
  IF remaining > 0 THEN
    RAISE EXCEPTION 'Not enough usable stock for "%": need %, only % in good, unexpired lots here',
      (SELECT name FROM product WHERE id = p_product), trim_scale(p_need), trim_scale(p_need - remaining);
  END IF;
END $$;

-- Add stock as a lot (creates the lot, or tops up an existing lot number). Untracked products just get stock.
CREATE OR REPLACE FUNCTION fn_stock_receive_lot(p_product int, p_wh int, p_qty numeric, p_reason text,
                                                p_ref_type text, p_ref_id int,
                                                p_lot_no text, p_expiry date, p_vendor int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE tr boolean; lid int; no text;
BEGIN
  SELECT tracked INTO tr FROM product WHERE id = p_product;
  IF NOT COALESCE(tr, false) THEN
    PERFORM fn_move_raw(p_product, p_wh, p_qty, p_reason, p_ref_type, p_ref_id, NULL);
    RETURN;
  END IF;
  no := COALESCE(NULLIF(trim(p_lot_no), ''),
                 'L' || to_char(current_date, 'YYMMDD') || '-' || lpad(nextval('lot_seq')::text, 4, '0'));
  INSERT INTO lot (product_id, lot_no, expiry_date, vendor_id, source)
  VALUES (p_product, no, p_expiry, p_vendor, p_reason)
  ON CONFLICT (product_id, lot_no) DO UPDATE SET expiry_date = COALESCE(EXCLUDED.expiry_date, lot.expiry_date)
  RETURNING id INTO lid;
  PERFORM fn_move_raw(p_product, p_wh, p_qty, p_reason, p_ref_type, p_ref_id, lid);
END $$;

-- The everyday entry point: in = new lot (automatic number), out = oldest-expiry lots first.
CREATE OR REPLACE FUNCTION fn_stock_move(p_product int, p_wh int, p_qty numeric,
                                         p_reason text, p_ref_type text DEFAULT NULL, p_ref_id int DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE tr boolean; a record;
BEGIN
  IF p_qty = 0 THEN RETURN; END IF;
  SELECT tracked INTO tr FROM product WHERE id = p_product;
  IF NOT COALESCE(tr, false) THEN
    PERFORM fn_move_raw(p_product, p_wh, p_qty, p_reason, p_ref_type, p_ref_id, NULL);
  ELSIF p_qty > 0 THEN
    PERFORM fn_stock_receive_lot(p_product, p_wh, p_qty, p_reason, p_ref_type, p_ref_id, NULL, NULL, NULL);
  ELSE
    FOR a IN SELECT * FROM fn_alloc_lots(p_product, p_wh, -p_qty) LOOP
      PERFORM fn_move_raw(p_product, p_wh, -a.alloc_qty, p_reason, p_ref_type, p_ref_id, a.alloc_lot);
    END LOOP;
  END IF;
END $$;

-- manual correction / opening stock: {product_id, warehouse_id, qty}  (qty may be negative)
CREATE OR REPLACE FUNCTION fn_adjust_stock(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE pid int := (p->>'product_id')::int; wh int := (p->>'warehouse_id')::int; q numeric := (p->>'qty')::numeric;
        lotno text := NULLIF(trim(COALESCE(p->>'lot_no', '')), ''); lid int;
BEGIN
  IF q IS NULL OR q = 0 THEN RAISE EXCEPTION 'Quantity cannot be zero'; END IF;
  IF q > 0 THEN
    PERFORM fn_stock_receive_lot(pid, wh, q, 'adjustment', NULL, NULL, lotno, (p->>'expiry_date')::date, NULL);
  ELSIF lotno IS NOT NULL AND (SELECT tracked FROM product WHERE id = pid) THEN
    SELECT id INTO lid FROM lot WHERE product_id = pid AND lot_no = lotno;
    IF lid IS NULL THEN RAISE EXCEPTION 'Lot "%" not found for this product', lotno; END IF;
    IF COALESCE((SELECT qty FROM lot_quant WHERE lot_id = lid AND warehouse_id = wh), 0) < -q THEN
      RAISE EXCEPTION 'Lot "%" has only % in this warehouse', lotno,
        COALESCE((SELECT qty FROM lot_quant WHERE lot_id = lid AND warehouse_id = wh), 0);
    END IF;
    PERFORM fn_move_raw(pid, wh, q, 'adjustment', NULL, NULL, lid);
  ELSE
    PERFORM fn_stock_move(pid, wh, q, 'adjustment');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------- CRM ----------
-- turn a lead into a customer: {id}
CREATE OR REPLACE FUNCTION fn_crm_convert(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE l crm_lead%ROWTYPE; pid int;
BEGIN
  SELECT * INTO l FROM crm_lead WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found'; END IF;
  pid := l.partner_id;
  IF pid IS NULL THEN
    INSERT INTO partner (name, kind, email, phone)
    VALUES (COALESCE(l.contact_name, l.title), 'customer', l.email, l.phone) RETURNING id INTO pid;
  END IF;
  UPDATE crm_lead SET partner_id = pid, stage = 'won' WHERE id = l.id;
  RETURN jsonb_build_object('partner_id', pid);
END $$;

-- ---------- Sales ----------
CREATE OR REPLACE FUNCTION fn_so_confirm(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE oid int := (p->>'id')::int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = oid) THEN
    RAISE EXCEPTION 'Add at least one line before confirming';
  END IF;
  UPDATE sales_order SET status = 'confirmed' WHERE id = oid AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft orders can be confirmed'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ship goods: stock goes down
CREATE OR REPLACE FUNCTION fn_so_deliver(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o sales_order%ROWTYPE; l record;
BEGIN
  SELECT * INTO o FROM sales_order WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND OR o.status <> 'confirmed' THEN RAISE EXCEPTION 'Only confirmed orders can be delivered'; END IF;
  FOR l IN SELECT * FROM sales_order_line WHERE order_id = o.id LOOP
    PERFORM fn_stock_move(l.product_id, o.warehouse_id, -l.qty, 'sale', 'sales_order', o.id);
  END LOOP;
  UPDATE sales_order SET status = 'delivered' WHERE id = o.id;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION fn_so_cancel(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sales_order SET status = 'cancelled' WHERE id = (p->>'id')::int AND status IN ('draft','confirmed');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft or confirmed orders can be cancelled'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------- Purchases ----------
CREATE OR REPLACE FUNCTION fn_po_confirm(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE oid int := (p->>'id')::int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM purchase_order_line WHERE order_id = oid) THEN
    RAISE EXCEPTION 'Add at least one line before confirming';
  END IF;
  UPDATE purchase_order SET status = 'confirmed' WHERE id = oid AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft orders can be confirmed'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- goods receipt: stock goes up and product cost follows the latest purchase price
CREATE OR REPLACE FUNCTION fn_po_receive(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o purchase_order%ROWTYPE; l record;
BEGIN
  SELECT * INTO o FROM purchase_order WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND OR o.status <> 'confirmed' THEN RAISE EXCEPTION 'Only confirmed orders can be received'; END IF;
  FOR l IN SELECT * FROM purchase_order_line WHERE order_id = o.id LOOP
    PERFORM fn_stock_receive_lot(l.product_id, o.warehouse_id, l.qty, 'purchase', 'purchase_order', o.id,
                                 COALESCE(NULLIF(l.lot_no, ''), o.number || '-L' || l.id), l.expiry_date, o.partner_id);
    UPDATE product SET cost = l.unit_cost WHERE id = l.product_id;
  END LOOP;
  UPDATE purchase_order SET status = 'received' WHERE id = o.id;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION fn_po_cancel(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE purchase_order SET status = 'cancelled' WHERE id = (p->>'id')::int AND status IN ('draft','confirmed');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft or confirmed orders can be cancelled'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------- Invoicing ----------
-- {kind: 'sales'|'purchase', order_id, due_days?}
-- one invoice line with GST worked out (CGST+SGST inside the state, IGST between states)
CREATE OR REPLACE FUNCTION fn_invoice_add_line(p_inv int, p_prod int, p_qty numeric, p_price numeric,
                                               p_disc numeric, p_intra boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE pr product%ROWTYPE; taxable numeric; c numeric := 0; s numeric := 0; i numeric := 0;
BEGIN
  SELECT * INTO pr FROM product WHERE id = p_prod;
  taxable := round(p_qty * p_price * (1 - p_disc / 100), 2);
  IF p_intra THEN
    c := round(taxable * pr.gst_rate / 200, 2); s := c;
  ELSE
    i := round(taxable * pr.gst_rate / 100, 2);
  END IF;
  INSERT INTO invoice_line (invoice_id, product_id, description, hsn_code, qty, unit_price, discount_pct,
                            taxable_value, gst_rate, cgst, sgst, igst, line_total)
  VALUES (p_inv, p_prod, pr.name, pr.hsn_code, p_qty, p_price, p_disc, taxable, pr.gst_rate, c, s, i, taxable + c + s + i);
END $$;

-- {kind: 'sales'|'purchase', order_id, due_days?}
CREATE OR REPLACE FUNCTION fn_create_invoice(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE kind text := p->>'kind'; oid int := (p->>'order_id')::int;
        days int := COALESCE((p->>'due_days')::int, 30);
        so sales_order%ROWTYPE; po purchase_order%ROWTYPE; inv_id int; inv_no text;
        pstate text; cstate text; intra boolean; l record;
        sub numeric; tc numeric; ts numeric; ti numeric; gross numeric; tot numeric;
BEGIN
  SELECT state_code INTO cstate FROM company;
  IF kind = 'sales' THEN
    SELECT * INTO so FROM sales_order WHERE id = oid;
    IF NOT FOUND OR so.status NOT IN ('confirmed','delivered') THEN
      RAISE EXCEPTION 'Order must be confirmed or delivered to invoice it';
    END IF;
    SELECT state_code INTO pstate FROM partner WHERE id = so.partner_id;
    intra := pstate IS NOT DISTINCT FROM cstate;
    INSERT INTO invoice (kind, partner_id, sales_order_id, due_date, total, supply_type, place_of_supply)
    VALUES ('customer', so.partner_id, oid, current_date + days, 0, CASE WHEN intra THEN 'intra' ELSE 'inter' END, pstate)
    RETURNING id, number INTO inv_id, inv_no;
    FOR l IN SELECT * FROM sales_order_line WHERE order_id = oid ORDER BY id LOOP
      PERFORM fn_invoice_add_line(inv_id, l.product_id, l.qty, l.unit_price, l.discount_pct, intra);
    END LOOP;
  ELSIF kind = 'purchase' THEN
    SELECT * INTO po FROM purchase_order WHERE id = oid;
    IF NOT FOUND OR po.status NOT IN ('confirmed','received') THEN
      RAISE EXCEPTION 'Order must be confirmed or received to invoice it';
    END IF;
    SELECT state_code INTO pstate FROM partner WHERE id = po.partner_id;
    intra := pstate IS NOT DISTINCT FROM cstate;
    INSERT INTO invoice (kind, partner_id, purchase_order_id, due_date, total, supply_type, place_of_supply)
    VALUES ('vendor', po.partner_id, oid, current_date + days, 0, CASE WHEN intra THEN 'intra' ELSE 'inter' END, pstate)
    RETURNING id, number INTO inv_id, inv_no;
    FOR l IN SELECT * FROM purchase_order_line WHERE order_id = oid ORDER BY id LOOP
      PERFORM fn_invoice_add_line(inv_id, l.product_id, l.qty, l.unit_cost, 0, intra);
    END LOOP;
  ELSE
    RAISE EXCEPTION 'kind must be sales or purchase';
  END IF;
  SELECT sum(taxable_value), sum(cgst), sum(sgst), sum(igst) INTO sub, tc, ts, ti FROM invoice_line WHERE invoice_id = inv_id;
  gross := COALESCE(sub, 0) + COALESCE(tc, 0) + COALESCE(ts, 0) + COALESCE(ti, 0);
  tot := round(gross);
  UPDATE invoice SET subtotal = COALESCE(sub, 0), cgst = COALESCE(tc, 0), sgst = COALESCE(ts, 0), igst = COALESCE(ti, 0),
                     round_off = tot - gross, total = tot
   WHERE id = inv_id;
  RETURN jsonb_build_object('invoice_id', inv_id, 'number', inv_no, 'total', tot);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'This order already has an invoice';
END $$;

-- keep invoice.paid / status in sync with payments
CREATE OR REPLACE FUNCTION trg_payment_apply() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE inv invoice%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM invoice WHERE id = NEW.invoice_id FOR UPDATE;
  IF NEW.amount > inv.total - inv.paid THEN
    RAISE EXCEPTION 'Payment % is more than the outstanding balance %', NEW.amount, inv.total - inv.paid;
  END IF;
  UPDATE invoice
     SET paid = inv.paid + NEW.amount,
         status = CASE WHEN inv.paid + NEW.amount >= inv.total THEN 'paid' ELSE 'partial' END
   WHERE id = inv.id;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS payment_apply ON payment;
CREATE TRIGGER payment_apply BEFORE INSERT ON payment FOR EACH ROW EXECUTE FUNCTION trg_payment_apply();

-- ---------- Manufacturing ----------
CREATE OR REPLACE FUNCTION fn_mo_start(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE production_order SET status = 'in_progress' WHERE id = (p->>'id')::int AND status = 'planned';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only planned orders can be started'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- consume components, produce finished goods
CREATE OR REPLACE FUNCTION fn_mo_complete(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE m production_order%ROWTYPE; b bom%ROWTYPE; l record;
BEGIN
  SELECT * INTO m FROM production_order WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND OR m.status NOT IN ('planned','in_progress') THEN
    RAISE EXCEPTION 'Only planned or in-progress orders can be completed';
  END IF;
  SELECT * INTO b FROM bom WHERE id = m.bom_id;
  FOR l IN SELECT * FROM bom_line WHERE bom_id = b.id LOOP
    PERFORM fn_stock_move(l.component_id, m.warehouse_id, -(l.qty * m.qty / b.output_qty), 'production_out', 'production_order', m.id);
  END LOOP;
  PERFORM fn_stock_receive_lot(b.product_id, m.warehouse_id, m.qty, 'production_in', 'production_order', m.id, m.number, NULL, NULL);
  UPDATE work_order SET status = 'done' WHERE production_order_id = m.id;
  UPDATE production_order SET status = 'done' WHERE id = m.id;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION fn_mo_cancel(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE production_order SET status = 'cancelled' WHERE id = (p->>'id')::int AND status IN ('planned','in_progress');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only planned or in-progress orders can be cancelled'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------- HR ----------
-- {employee_id, period_start, period_end, deduction_pct?}  hours come from timesheets
CREATE OR REPLACE FUNCTION fn_generate_payslip(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE e employee%ROWTYPE; hrs numeric; gross numeric; ded numeric; s payslip%ROWTYPE;
        d1 date := (p->>'period_start')::date; d2 date := (p->>'period_end')::date;
        pct numeric := COALESCE((p->>'deduction_pct')::numeric, 0);
BEGIN
  SELECT * INTO e FROM employee WHERE id = (p->>'employee_id')::int;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
  SELECT COALESCE(sum(hours), 0) INTO hrs FROM timesheet
   WHERE employee_id = e.id AND work_date BETWEEN d1 AND d2;
  IF hrs = 0 THEN RAISE EXCEPTION 'No timesheet hours for % in this period', e.name; END IF;
  gross := round(hrs * e.hourly_rate, 2);
  ded := round(gross * pct / 100, 2);
  INSERT INTO payslip (employee_id, period_start, period_end, hours, gross, deductions, net)
  VALUES (e.id, d1, d2, hrs, gross, ded, gross - ded) RETURNING * INTO s;
  RETURN to_jsonb(s);
END $$;

-- ---------- POS ----------
-- {register_id, items:[{barcode|product_id, qty}], discount_pct?, method?}
CREATE OR REPLACE FUNCTION fn_pos_checkout(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE reg cash_register%ROWTYPE; sid int; snum text; item jsonb; prod product%ROWTYPE;
        q numeric; sub numeric := 0; disc numeric := COALESCE((p->>'discount_pct')::numeric, 0); tot numeric;
        meth text := COALESCE(p->>'method', 'cash');
BEGIN
  SELECT * INTO reg FROM cash_register WHERE id = (p->>'register_id')::int FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cash register not found'; END IF;
  IF reg.status <> 'open' THEN RAISE EXCEPTION 'Cash register is closed'; END IF;
  IF jsonb_array_length(COALESCE(p->'items', '[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Cart is empty'; END IF;

  INSERT INTO pos_sale (register_id, discount_pct, payment_method) VALUES (reg.id, disc, meth)
  RETURNING id, number INTO sid, snum;

  FOR item IN SELECT * FROM jsonb_array_elements(p->'items') LOOP
    q := COALESCE((item->>'qty')::numeric, 1);
    IF item ? 'product_id' THEN
      SELECT * INTO prod FROM product WHERE id = (item->>'product_id')::int AND active;
    ELSE
      SELECT * INTO prod FROM product WHERE barcode = item->>'barcode' AND active;
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found: %', COALESCE(item->>'barcode', item->>'product_id'); END IF;
    INSERT INTO pos_sale_line (sale_id, product_id, qty, unit_price) VALUES (sid, prod.id, q, prod.price);
    PERFORM fn_stock_move(prod.id, reg.warehouse_id, -q, 'pos', 'pos_sale', sid);
    sub := sub + q * prod.price;
  END LOOP;

  tot := round(sub * (1 - disc / 100), 2);
  UPDATE pos_sale SET total = tot WHERE id = sid;
  IF meth = 'cash' THEN UPDATE cash_register SET balance = balance + tot WHERE id = reg.id; END IF;
  RETURN jsonb_build_object('sale_id', sid, 'number', snum, 'subtotal', sub, 'discount_pct', disc, 'total', tot);
END $$;

-- ---------- Dashboard ----------
CREATE OR REPLACE FUNCTION fn_dashboard(p jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
SELECT jsonb_build_object(
  'products',             (SELECT count(*) FROM product WHERE active),
  'stock_value',          (SELECT COALESCE(round(sum(q.qty * pr.cost), 2), 0) FROM stock_quant q JOIN product pr ON pr.id = q.product_id),
  'low_stock',            (SELECT count(*) FROM v_product WHERE low_stock),
  'open_sales_orders',    (SELECT count(*) FROM sales_order WHERE status IN ('draft','confirmed')),
  'open_purchase_orders', (SELECT count(*) FROM purchase_order WHERE status IN ('draft','confirmed')),
  'receivable',           (SELECT COALESCE(sum(total - paid), 0) FROM invoice WHERE kind = 'customer' AND status <> 'paid'),
  'payable',              (SELECT COALESCE(sum(total - paid), 0) FROM invoice WHERE kind = 'vendor' AND status <> 'paid'),
  'overdue_invoices',     (SELECT count(*) FROM v_invoice WHERE overdue),
  'pos_today',            (SELECT COALESCE(sum(total), 0) FROM pos_sale WHERE created_at::date = current_date),
  'open_leads',           (SELECT count(*) FROM crm_lead WHERE stage NOT IN ('won','lost')),
  'running_production',   (SELECT count(*) FROM production_order WHERE status IN ('planned','in_progress')),
  'active_projects',      (SELECT count(*) FROM project WHERE status = 'active'),
  'employees',            (SELECT count(*) FROM employee WHERE active),
  'expiring_lots',        (SELECT count(*) FROM v_lot WHERE on_hand > 0 AND state IN ('expiring','expired')),
  'qc_failed_30d',        (SELECT count(*) FROM qc_inspection WHERE status = 'failed' AND inspected_on >= current_date - 30),
  'low_stock_items',      (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM
                             (SELECT sku, name, on_hand, reorder_level FROM v_product WHERE low_stock ORDER BY on_hand LIMIT 8) x),
  'recent_moves',         (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM
                             (SELECT m.created_at, pr.name AS product, w.name AS warehouse, m.qty, m.reason
                                FROM stock_move m JOIN product pr ON pr.id = m.product_id JOIN warehouse w ON w.id = m.warehouse_id
                               ORDER BY m.id DESC LIMIT 8) x),
  'sales_7d',             (SELECT jsonb_agg(jsonb_build_object('day', to_char(d, 'DD Mon'),
                              'pos',      (SELECT COALESCE(sum(total), 0) FROM pos_sale WHERE created_at::date = d),
                              'invoiced', (SELECT COALESCE(sum(total), 0) FROM invoice WHERE kind = 'customer' AND issue_date = d)) ORDER BY d)
                             FROM generate_series(current_date - 6, current_date, '1 day') d)
);
$$;

-- ---------- Transfers & reordering ----------
-- move stock between warehouses: {product_id, from_warehouse_id, to_warehouse_id, qty}
CREATE OR REPLACE FUNCTION fn_transfer_stock(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE pid int := (p->>'product_id')::int; a int := (p->>'from_warehouse_id')::int;
        b int := (p->>'to_warehouse_id')::int; q numeric := (p->>'qty')::numeric; s record;
BEGIN
  IF a = b THEN RAISE EXCEPTION 'Choose two different warehouses'; END IF;
  IF q IS NULL OR q <= 0 THEN RAISE EXCEPTION 'Quantity must be more than zero'; END IF;
  IF (SELECT tracked FROM product WHERE id = pid) THEN
    -- the same lots arrive at the other warehouse, so traceability is kept
    FOR s IN SELECT * FROM fn_alloc_lots(pid, a, q) LOOP
      PERFORM fn_move_raw(pid, a, -s.alloc_qty, 'transfer_out', NULL, NULL, s.alloc_lot);
      PERFORM fn_move_raw(pid, b,  s.alloc_qty, 'transfer_in',  NULL, NULL, s.alloc_lot);
    END LOOP;
  ELSE
    PERFORM fn_stock_move(pid, a, -q, 'transfer_out');
    PERFORM fn_stock_move(pid, b,  q, 'transfer_in');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- one draft purchase order per preferred vendor for everything on the reorder list: {warehouse_id}
CREATE OR REPLACE FUNCTION fn_reorder_create_pos(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v record; r record; po_id int; po_num text; wh int := (p->>'warehouse_id')::int;
        orders int := 0; lines int := 0; nums text[] := '{}';
BEGIN
  IF wh IS NULL THEN RAISE EXCEPTION 'Choose the warehouse to deliver to'; END IF;
  FOR v IN SELECT DISTINCT vendor_id FROM v_reorder WHERE vendor_id IS NOT NULL LOOP
    INSERT INTO purchase_order (partner_id, warehouse_id, notes)
    VALUES (v.vendor_id, wh, 'Created from reorder suggestions') RETURNING id, number INTO po_id, po_num;
    FOR r IN SELECT ro.id, ro.suggested_qty, pr.cost FROM v_reorder ro JOIN product pr ON pr.id = ro.id
              WHERE ro.vendor_id = v.vendor_id LOOP
      INSERT INTO purchase_order_line (order_id, product_id, qty, unit_cost) VALUES (po_id, r.id, r.suggested_qty, r.cost);
      lines := lines + 1;
    END LOOP;
    orders := orders + 1; nums := nums || po_num;
  END LOOP;
  IF orders = 0 THEN
    RAISE EXCEPTION 'Nothing to reorder: no low-stock product with a preferred vendor that is not already on an open order';
  END IF;
  RETURN jsonb_build_object('orders', orders, 'lines', lines, 'numbers', to_jsonb(nums));
END $$;

-- ---------- Quotations ----------
CREATE OR REPLACE FUNCTION fn_qt_send(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE qid int := (p->>'id')::int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM quotation_line WHERE quotation_id = qid) THEN
    RAISE EXCEPTION 'Add at least one line before sending';
  END IF;
  UPDATE quotation SET status = 'sent' WHERE id = qid AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft quotations can be sent'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION fn_qt_accept(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE quotation SET status = 'accepted' WHERE id = (p->>'id')::int AND status = 'sent';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only sent quotations can be marked accepted'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION fn_qt_reject(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE quotation SET status = 'rejected' WHERE id = (p->>'id')::int AND status IN ('sent','accepted');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only sent quotations can be marked rejected'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- back to draft so prices can be revised; validity is extended
CREATE OR REPLACE FUNCTION fn_qt_reopen(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE quotation SET status = 'draft', valid_until = GREATEST(valid_until, current_date + 15)
   WHERE id = (p->>'id')::int AND status IN ('sent','accepted','rejected');
  IF NOT FOUND THEN RAISE EXCEPTION 'This quotation cannot be reopened'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- {id, warehouse_id}: becomes a draft sales order with the same lines
CREATE OR REPLACE FUNCTION fn_qt_convert(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE q quotation%ROWTYPE; so_id int; so_no text; wh int := (p->>'warehouse_id')::int;
BEGIN
  SELECT * INTO q FROM quotation WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND OR q.status NOT IN ('sent','accepted') THEN
    RAISE EXCEPTION 'Only sent or accepted quotations can be turned into an order';
  END IF;
  IF q.valid_until < current_date THEN
    RAISE EXCEPTION 'This quotation expired on %. Reopen it to extend the validity first.', to_char(q.valid_until, 'DD Mon YYYY');
  END IF;
  IF wh IS NULL THEN RAISE EXCEPTION 'Choose the warehouse the order ships from'; END IF;
  INSERT INTO sales_order (partner_id, warehouse_id, notes)
  VALUES (q.partner_id, wh, 'From quotation ' || q.number) RETURNING id, number INTO so_id, so_no;
  INSERT INTO sales_order_line (order_id, product_id, qty, unit_price, discount_pct)
  SELECT so_id, product_id, qty, unit_price, discount_pct FROM quotation_line WHERE quotation_id = q.id ORDER BY id;
  UPDATE quotation SET status = 'converted', sales_order_id = so_id WHERE id = q.id;
  UPDATE crm_lead SET stage = 'won' WHERE id = q.lead_id AND stage <> 'lost';
  RETURN jsonb_build_object('sales_order_id', so_id, 'number', so_no);
END $$;

-- ---------- Quality control ----------
-- {id, disposition?, rejection_reason?}: all readings in spec = passed. A failed lot is blocked from use.
CREATE OR REPLACE FUNCTION fn_qc_complete(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE q qc_inspection%ROWTYPE; failed boolean; disp text := NULLIF(p->>'disposition', '');
BEGIN
  SELECT * INTO q FROM qc_inspection WHERE id = (p->>'id')::int FOR UPDATE;
  IF NOT FOUND OR q.status <> 'open' THEN RAISE EXCEPTION 'Only open inspections can be completed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qc_result WHERE inspection_id = q.id) THEN
    RAISE EXCEPTION 'Record at least one test result first';
  END IF;
  failed := EXISTS (SELECT 1 FROM qc_result WHERE inspection_id = q.id AND NOT passed);
  IF failed THEN
    IF disp IS NULL THEN RAISE EXCEPTION 'Some readings are out of spec: choose what happens to the material (accept, rework, scrap or return to vendor)'; END IF;
    UPDATE qc_inspection SET status = 'failed', disposition = disp, rejection_reason = NULLIF(p->>'rejection_reason', '') WHERE id = q.id;
    IF q.lot_id IS NOT NULL AND disp <> 'accept' THEN UPDATE lot SET quality_status = 'rejected' WHERE id = q.lot_id; END IF;
  ELSE
    UPDATE qc_inspection SET status = 'passed', disposition = 'accept' WHERE id = q.id;
    IF q.lot_id IS NOT NULL THEN UPDATE lot SET quality_status = 'ok' WHERE id = q.lot_id; END IF;
  END IF;
  RETURN jsonb_build_object('result', CASE WHEN failed THEN 'failed' ELSE 'passed' END);
END $$;

-- ---------- Data for PDF documents (one JSON document per print) ----------
CREATE OR REPLACE FUNCTION fn_doc_invoice(p_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'company', (SELECT to_jsonb(c) FROM company c),
  'invoice', to_jsonb(v),
  'partner', (SELECT to_jsonb(pr) FROM partner pr WHERE pr.id = v.partner_id),
  'order_ref', COALESCE((SELECT number FROM sales_order WHERE id = v.sales_order_id), (SELECT number FROM purchase_order WHERE id = v.purchase_order_id)),
  'lines', (SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id), '[]'::jsonb) FROM invoice_line l WHERE l.invoice_id = v.id))
FROM v_invoice v WHERE v.id = p_id;
$$;

CREATE OR REPLACE FUNCTION fn_doc_quotation(p_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'company', (SELECT to_jsonb(c) FROM company c),
  'quotation', to_jsonb(v),
  'partner', (SELECT to_jsonb(pr) FROM partner pr WHERE pr.id = v.partner_id),
  'intra', (SELECT pr.state_code IS NOT DISTINCT FROM c.state_code FROM partner pr, company c WHERE pr.id = v.partner_id),
  'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'name', pr.name, 'hsn_code', pr.hsn_code, 'gst_rate', pr.gst_rate, 'qty', l.qty,
              'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
              'taxable', round(l.qty * l.unit_price * (1 - l.discount_pct / 100), 2)) ORDER BY l.id), '[]'::jsonb)
            FROM quotation_line l JOIN product pr ON pr.id = l.product_id WHERE l.quotation_id = v.id))
FROM v_quotation v WHERE v.id = p_id;
$$;

CREATE OR REPLACE FUNCTION fn_doc_qc(p_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'company', (SELECT to_jsonb(c) FROM company c),
  'inspection', to_jsonb(v),
  'product', (SELECT to_jsonb(pr) FROM product pr WHERE pr.id = v.product_id),
  'lot', (SELECT to_jsonb(l) FROM v_lot l WHERE l.id = v.lot_id),
  'inspector', (SELECT name FROM employee WHERE id = v.inspector_id),
  'purchase_order', (SELECT number FROM purchase_order WHERE id = v.purchase_order_id),
  'production_order', (SELECT number FROM production_order WHERE id = v.production_order_id),
  'results', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb) FROM qc_result r WHERE r.inspection_id = v.id))
FROM v_qc_inspection v WHERE v.id = p_id;
$$;

CREATE OR REPLACE FUNCTION fn_doc_payslip(p_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'company', (SELECT to_jsonb(c) FROM company c),
  'payslip', to_jsonb(s),
  'employee', (SELECT jsonb_build_object('name', e.name, 'job_title', e.job_title, 'hourly_rate', e.hourly_rate, 'hire_date', e.hire_date)
                 FROM employee e WHERE e.id = s.employee_id))
FROM payslip s WHERE s.id = p_id;
$$;

-- ---------- Users & login ----------
-- Password rules: 10+ characters, a letter and a digit, not the username, not an obvious password.
CREATE OR REPLACE FUNCTION fn_check_password(pw text, uname text) RETURNS void LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF length(COALESCE(pw, '')) < 10 THEN RAISE EXCEPTION 'Password must be at least 10 characters'; END IF;
  IF length(pw) > 200 THEN RAISE EXCEPTION 'Password is too long'; END IF;
  IF pw !~ '[A-Za-z]' OR pw !~ '[0-9]' THEN RAISE EXCEPTION 'Password must contain at least one letter and one digit'; END IF;
  IF uname IS NOT NULL AND position(lower(uname) in lower(pw)) > 0 THEN RAISE EXCEPTION 'Password must not contain the username'; END IF;
  IF lower(pw) ~ '(password|qwerty|123456|admin123|stockmate|filtsap|letmein|welcome)' THEN
    RAISE EXCEPTION 'That password is too easy to guess. Choose something less predictable';
  END IF;
END $$;

-- {username, password} -> {username, full_name, role, must_change}
CREATE OR REPLACE FUNCTION fn_login(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u app_user%ROWTYPE;
BEGIN
  SELECT * INTO u FROM app_user WHERE username = lower(trim(COALESCE(p->>'username', ''))) AND active;
  IF NOT FOUND THEN
    PERFORM crypt('x', gen_salt('bf', 10));   -- same cost whether or not the user exists
    RAISE EXCEPTION 'Wrong username or password';
  END IF;
  IF u.password_hash <> crypt(COALESCE(p->>'password', ''), u.password_hash) THEN
    RAISE EXCEPTION 'Wrong username or password';
  END IF;
  RETURN jsonb_build_object('username', u.username, 'full_name', u.full_name, 'role', u.role, 'must_change', u.must_change);
END $$;

-- {username, full_name, role, password}: the new user must choose their own password at first sign-in
CREATE OR REPLACE FUNCTION fn_create_user(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE pw text := COALESCE(p->>'password', ''); uid int; un text := lower(trim(COALESCE(p->>'username', '')));
BEGIN
  IF un !~ '^[a-z0-9._-]{3,40}$' THEN RAISE EXCEPTION 'Username must be 3-40 characters: lower-case letters, digits, dot, dash or underscore'; END IF;
  PERFORM fn_check_password(pw, un);
  IF p->>'role' IS NULL OR p->>'role' NOT IN ('admin','sales','store','accounts','hr','cashier','viewer') THEN
    RAISE EXCEPTION 'Unknown role';
  END IF;
  INSERT INTO app_user (username, full_name, role, password_hash, must_change)
  VALUES (un, left(p->>'full_name', 100), p->>'role', crypt(pw, gen_salt('bf', 10)), true)
  RETURNING id INTO uid;
  RETURN jsonb_build_object('id', uid);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'That username is already taken';
END $$;

-- admin resets someone's password: {id, password}; they must replace it at next sign-in
CREATE OR REPLACE FUNCTION fn_set_password(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE pw text := COALESCE(p->>'password', ''); un text;
BEGIN
  SELECT username INTO un FROM app_user WHERE id = (p->>'id')::int;
  IF un IS NULL THEN RAISE EXCEPTION 'User not found'; END IF;
  PERFORM fn_check_password(pw, un);
  UPDATE app_user SET password_hash = crypt(pw, gen_salt('bf', 10)), must_change = true WHERE username = un;
  RETURN jsonb_build_object('ok', true);
END $$;

-- a user changes their own password: ('name', {old_password, new_password})
CREATE OR REPLACE FUNCTION fn_change_password(uname text, p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE u app_user%ROWTYPE; pw text := COALESCE(p->>'new_password', '');
BEGIN
  SELECT * INTO u FROM app_user WHERE username = uname AND active;
  IF NOT FOUND OR u.password_hash <> crypt(COALESCE(p->>'old_password', ''), u.password_hash) THEN
    RAISE EXCEPTION 'Current password is wrong';
  END IF;
  IF pw = COALESCE(p->>'old_password', '') THEN RAISE EXCEPTION 'Choose a password different from the current one'; END IF;
  PERFORM fn_check_password(pw, uname);
  UPDATE app_user SET password_hash = crypt(pw, gen_salt('bf', 10)), must_change = false WHERE id = u.id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- activate / deactivate a user: {id, active}; there must always be one active admin left
CREATE OR REPLACE FUNCTION fn_set_user_active(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE uid int := (p->>'id')::int; flag boolean := (p->>'active')::boolean;
BEGIN
  UPDATE app_user SET active = flag WHERE id = uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM app_user WHERE role = 'admin' AND active) THEN
    RAISE EXCEPTION 'At least one active admin is required';
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------- Generic CRUD helpers used by the Java API ----------
-- The table name is checked against a fixed whitelist in Java and quoted with %I here.
CREATE OR REPLACE FUNCTION api_insert(t text, body jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE cols text; r jsonb; clean jsonb := jsonb_strip_nulls(body);
BEGIN
  IF t IN ('sales_order','purchase_order','production_order','quotation','qc_inspection') THEN
    clean := clean - 'status' - 'number' - 'sales_order_id' - 'disposition';   -- status only changes through the action functions
  END IF;
  SELECT string_agg(quote_ident(c.column_name), ', ') INTO cols
    FROM information_schema.columns c
   WHERE c.table_schema = 'public' AND c.table_name = t AND c.column_name <> 'id'
     AND c.column_name IN (SELECT jsonb_object_keys(clean));
  IF cols IS NULL THEN RAISE EXCEPTION 'No valid fields supplied'; END IF;
  EXECUTE format('INSERT INTO %I (%s) SELECT %s FROM jsonb_populate_record(null::%I, $1) RETURNING to_jsonb(%I.*)',
                 t, cols, cols, t, t) INTO r USING clean;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION api_update(t text, rid int, body jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE sets text; r jsonb;
BEGIN
  IF t IN ('sales_order','purchase_order','production_order','quotation','qc_inspection') THEN
    body := body - 'status' - 'number' - 'sales_order_id' - 'disposition';
  END IF;
  SELECT string_agg(format('%I = r.%I', c.column_name, c.column_name), ', ') INTO sets
    FROM information_schema.columns c
   WHERE c.table_schema = 'public' AND c.table_name = t AND c.column_name <> 'id'
     AND c.column_name IN (SELECT jsonb_object_keys(body));
  IF sets IS NULL THEN RAISE EXCEPTION 'No valid fields supplied'; END IF;
  EXECUTE format('UPDATE %I SET %s FROM jsonb_populate_record(null::%I, $1) r WHERE %I.id = $2 RETURNING to_jsonb(%I.*)',
                 t, sets, t, t, t) INTO r USING body, rid;
  IF r IS NULL THEN RAISE EXCEPTION 'Record not found'; END IF;
  RETURN r;
END $$;

-- ---------- Integrity guards ----------
-- order lines can only change while the order is still a draft
CREATE OR REPLACE FUNCTION trg_lines_draft_only() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent text := TG_ARGV[0]; col text := TG_ARGV[1]; allowed text := TG_ARGV[2]; oid int; st text;
BEGIN
  oid := (to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END) ->> col)::int;
  EXECUTE format('SELECT status FROM %I WHERE id = $1', parent) INTO st USING oid;
  IF st IS NOT NULL AND st <> allowed THEN
    RAISE EXCEPTION 'Lines can only be changed while the status is "%" (this one is "%")', allowed, st;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS so_lines_guard ON sales_order_line;
CREATE TRIGGER so_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON sales_order_line
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('sales_order', 'order_id', 'draft');
DROP TRIGGER IF EXISTS po_lines_guard ON purchase_order_line;
CREATE TRIGGER po_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_line
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('purchase_order', 'order_id', 'draft');

DROP TRIGGER IF EXISTS qt_lines_guard ON quotation_line;
CREATE TRIGGER qt_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON quotation_line
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('quotation', 'quotation_id', 'draft');
DROP TRIGGER IF EXISTS qc_results_guard ON qc_result;
CREATE TRIGGER qc_results_guard BEFORE INSERT OR UPDATE OR DELETE ON qc_result
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('qc_inspection', 'inspection_id', 'open');

CREATE OR REPLACE FUNCTION trg_qc_lot_match() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.lot_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM lot WHERE id = NEW.lot_id AND product_id = NEW.product_id) THEN
    RAISE EXCEPTION 'The chosen lot belongs to a different product';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS qc_lot_match ON qc_inspection;
CREATE TRIGGER qc_lot_match BEFORE INSERT OR UPDATE ON qc_inspection FOR EACH ROW EXECUTE FUNCTION trg_qc_lot_match();

-- Document headers can only be edited (or deleted) while still in their first state; after that only the action functions change them.
-- args: editable status, then the columns the action functions are allowed to change.
CREATE OR REPLACE FUNCTION trg_header_lock() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE editable text := TG_ARGV[0]; excl text[] := TG_ARGV[2:]; o jsonb; n jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> editable THEN
      RAISE EXCEPTION 'This % is "%" and can no longer be deleted', replace(TG_TABLE_NAME, '_', ' '), OLD.status;
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status <> editable THEN
    o := to_jsonb(OLD) - excl; n := to_jsonb(NEW) - excl;
    IF o <> n THEN
      RAISE EXCEPTION 'This % is "%" and can no longer be edited', replace(TG_TABLE_NAME, '_', ' '), OLD.status;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS so_header_lock ON sales_order;
CREATE TRIGGER so_header_lock BEFORE UPDATE OR DELETE ON sales_order FOR EACH ROW EXECUTE FUNCTION trg_header_lock('draft', 'x', 'status');
DROP TRIGGER IF EXISTS po_header_lock ON purchase_order;
CREATE TRIGGER po_header_lock BEFORE UPDATE OR DELETE ON purchase_order FOR EACH ROW EXECUTE FUNCTION trg_header_lock('draft', 'x', 'status');
DROP TRIGGER IF EXISTS mo_header_lock ON production_order;
CREATE TRIGGER mo_header_lock BEFORE UPDATE OR DELETE ON production_order FOR EACH ROW EXECUTE FUNCTION trg_header_lock('planned', 'x', 'status');
DROP TRIGGER IF EXISTS qt_header_lock ON quotation;
CREATE TRIGGER qt_header_lock BEFORE UPDATE OR DELETE ON quotation FOR EACH ROW EXECUTE FUNCTION trg_header_lock('draft', 'x', 'status', 'sales_order_id', 'valid_until');
DROP TRIGGER IF EXISTS qc_header_lock ON qc_inspection;
CREATE TRIGGER qc_header_lock BEFORE UPDATE OR DELETE ON qc_inspection FOR EACH ROW EXECUTE FUNCTION trg_header_lock('open', 'x', 'status', 'disposition', 'rejection_reason');

-- the company record is needed for every invoice
CREATE OR REPLACE FUNCTION trg_company_keep() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Company settings cannot be deleted'; END $$;
DROP TRIGGER IF EXISTS company_keep ON company;
CREATE TRIGGER company_keep BEFORE DELETE ON company FOR EACH ROW EXECUTE FUNCTION trg_company_keep();

-- the audit log is append-only
CREATE OR REPLACE FUNCTION trg_audit_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'The audit log cannot be changed or deleted'; END $$;
DROP TRIGGER IF EXISTS audit_append_only ON audit_log;
CREATE TRIGGER audit_append_only BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION trg_audit_append_only();

-- payments are a ledger: no edits, no deletes
CREATE OR REPLACE FUNCTION trg_payment_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Payments cannot be edited or deleted';
END $$;
DROP TRIGGER IF EXISTS payment_immutable ON payment;
CREATE TRIGGER payment_immutable BEFORE UPDATE OR DELETE ON payment
  FOR EACH ROW EXECUTE FUNCTION trg_payment_immutable();
