-- StockMate: business logic in PL/pgSQL.
-- Every "action" function takes one jsonb argument and returns jsonb,
-- so the Java backend can call them all the same way: SELECT fn_xxx(?::jsonb)

-- ---------- Stock core ----------
CREATE OR REPLACE FUNCTION fn_stock_move(p_product int, p_wh int, p_qty numeric,
                                         p_reason text, p_ref_type text DEFAULT NULL, p_ref_id int DEFAULT NULL)
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
  INSERT INTO stock_move (product_id, warehouse_id, qty, reason, ref_type, ref_id)
  VALUES (p_product, p_wh, p_qty, p_reason, p_ref_type, p_ref_id);
END $$;

-- manual correction / opening stock: {product_id, warehouse_id, qty}  (qty may be negative)
CREATE OR REPLACE FUNCTION fn_adjust_stock(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  PERFORM fn_stock_move((p->>'product_id')::int, (p->>'warehouse_id')::int, (p->>'qty')::numeric, 'adjustment');
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
    PERFORM fn_stock_move(l.product_id, o.warehouse_id, l.qty, 'purchase', 'purchase_order', o.id);
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
CREATE OR REPLACE FUNCTION fn_create_invoice(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE kind text := p->>'kind'; oid int := (p->>'order_id')::int;
        days int := COALESCE((p->>'due_days')::int, 30);
        so sales_order%ROWTYPE; po purchase_order%ROWTYPE; tot numeric; inv invoice%ROWTYPE;
BEGIN
  IF kind = 'sales' THEN
    SELECT * INTO so FROM sales_order WHERE id = oid;
    IF NOT FOUND OR so.status NOT IN ('confirmed','delivered') THEN
      RAISE EXCEPTION 'Order must be confirmed or delivered to invoice it';
    END IF;
    SELECT total INTO tot FROM v_sales_order WHERE id = oid;
    INSERT INTO invoice (kind, partner_id, sales_order_id, due_date, total)
    VALUES ('customer', so.partner_id, oid, current_date + days, tot) RETURNING * INTO inv;
  ELSIF kind = 'purchase' THEN
    SELECT * INTO po FROM purchase_order WHERE id = oid;
    IF NOT FOUND OR po.status NOT IN ('confirmed','received') THEN
      RAISE EXCEPTION 'Order must be confirmed or received to invoice it';
    END IF;
    SELECT total INTO tot FROM v_purchase_order WHERE id = oid;
    INSERT INTO invoice (kind, partner_id, purchase_order_id, due_date, total)
    VALUES ('vendor', po.partner_id, oid, current_date + days, tot) RETURNING * INTO inv;
  ELSE
    RAISE EXCEPTION 'kind must be sales or purchase';
  END IF;
  RETURN jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'total', inv.total);
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
  PERFORM fn_stock_move(b.product_id, m.warehouse_id, m.qty, 'production_in', 'production_order', m.id);
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

-- ---------- Generic CRUD helpers used by the Java API ----------
-- The table name is checked against a fixed whitelist in Java and quoted with %I here.
CREATE OR REPLACE FUNCTION api_insert(t text, body jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE cols text; r jsonb; clean jsonb := jsonb_strip_nulls(body);
BEGIN
  IF t IN ('sales_order','purchase_order','production_order') THEN
    clean := clean - 'status' - 'number';   -- status only changes through the action functions
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
  IF t IN ('sales_order','purchase_order','production_order') THEN
    body := body - 'status' - 'number';
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
DECLARE parent text := TG_ARGV[0]; oid int; st text;
BEGIN
  oid := CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
  EXECUTE format('SELECT status FROM %I WHERE id = $1', parent) INTO st USING oid;
  IF st IS NOT NULL AND st <> 'draft' THEN
    RAISE EXCEPTION 'Lines can only be changed while the order is a draft (this one is %)', st;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS so_lines_guard ON sales_order_line;
CREATE TRIGGER so_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON sales_order_line
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('sales_order');
DROP TRIGGER IF EXISTS po_lines_guard ON purchase_order_line;
CREATE TRIGGER po_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_line
  FOR EACH ROW EXECUTE FUNCTION trg_lines_draft_only('purchase_order');

-- payments are a ledger: no edits, no deletes
CREATE OR REPLACE FUNCTION trg_payment_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Payments cannot be edited or deleted';
END $$;
DROP TRIGGER IF EXISTS payment_immutable ON payment;
CREATE TRIGGER payment_immutable BEFORE UPDATE OR DELETE ON payment
  FOR EACH ROW EXECUTE FUNCTION trg_payment_immutable();
