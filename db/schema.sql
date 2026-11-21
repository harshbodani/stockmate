-- StockMate: database schema (PostgreSQL 14+)
-- Modules: Core/Stock, CRM, Sales, Purchases, Invoicing, Manufacturing, Projects, HR, POS

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- password hashing (bcrypt)

CREATE SEQUENCE so_seq;
CREATE SEQUENCE po_seq;
CREATE SEQUENCE inv_seq;
CREATE SEQUENCE mo_seq;
CREATE SEQUENCE pos_seq;
CREATE SEQUENCE lot_seq;
CREATE SEQUENCE qt_seq;
CREATE SEQUENCE qc_seq;

-- ---------- Company details used on invoices (single row) ----------
CREATE TABLE company (
  id            int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  name          text NOT NULL,
  address       text,
  gstin         text,
  state_code    text NOT NULL,       -- 2-digit GST state code, e.g. 24 = Gujarat
  state_name    text,
  phone         text,
  email         text,
  bank_details  text,
  invoice_terms text
);

-- GST on one line: intra-state = CGST + SGST (half each), inter-state = IGST
CREATE FUNCTION fn_gst_tax(taxable numeric, rate numeric, intra boolean) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN COALESCE(intra, true) THEN 2 * round(taxable * rate / 200, 2) ELSE round(taxable * rate / 100, 2) END
$$;

-- ---------- Core: partners, warehouses, products ----------
CREATE TABLE partner (
  id         serial PRIMARY KEY,
  name       text NOT NULL,
  kind       text NOT NULL DEFAULT 'customer' CHECK (kind IN ('customer','vendor','both')),
  email      text,
  phone      text,
  address    text,
  gstin      text,
  state_code text,                  -- 2-digit GST state code
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE warehouse (
  id       serial PRIMARY KEY,
  name     text NOT NULL UNIQUE,
  location text
);

CREATE TABLE product (
  id            serial PRIMARY KEY,
  sku           text NOT NULL UNIQUE,
  barcode       text UNIQUE,
  name          text NOT NULL,
  category      text,
  unit          text NOT NULL DEFAULT 'pcs',
  cost          numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost >= 0),
  price         numeric(12,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  reorder_level numeric(14,3) NOT NULL DEFAULT 0,
  active        boolean NOT NULL DEFAULT true,
  -- filtration specifications (used for searching and compatibility)
  micron        numeric(8,2),          -- filtration rating in microns
  size          text,                  -- e.g. 10 inch, 20 inch
  material      text,                  -- e.g. polypropylene, cellulose
  flow_rate     text,                  -- e.g. 500 LPH
  fits_models   text,                  -- housings / machines this part fits
  vendor_id     int REFERENCES partner(id),   -- preferred vendor for reordering
  reorder_qty   numeric(14,3) NOT NULL DEFAULT 0,  -- usual order quantity (0 = automatic suggestion)
  tracked       boolean NOT NULL DEFAULT false,     -- batch / lot tracking
  hsn_code      text,                               -- GST HSN code
  gst_rate      numeric(5,2) NOT NULL DEFAULT 18 CHECK (gst_rate BETWEEN 0 AND 50)
);

-- current stock per product per warehouse
CREATE TABLE stock_quant (
  product_id   int NOT NULL REFERENCES product(id) ON DELETE CASCADE,
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  qty          numeric(14,3) NOT NULL DEFAULT 0 CHECK (qty >= 0),
  PRIMARY KEY (product_id, warehouse_id)
);

-- batch / lot tracking (only for products with tracked = true)
CREATE TABLE lot (
  id             serial PRIMARY KEY,
  product_id     int NOT NULL REFERENCES product(id),
  lot_no         text NOT NULL,
  received_date  date NOT NULL DEFAULT current_date,
  expiry_date    date,
  vendor_id      int REFERENCES partner(id),
  source         text NOT NULL DEFAULT 'adjustment',   -- purchase, production_in, adjustment
  quality_status text NOT NULL DEFAULT 'ok' CHECK (quality_status IN ('ok','rejected')),
  notes          text,
  UNIQUE (product_id, lot_no)
);

CREATE TABLE lot_quant (
  lot_id       int NOT NULL REFERENCES lot(id) ON DELETE CASCADE,
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  qty          numeric(14,3) NOT NULL DEFAULT 0 CHECK (qty >= 0),
  PRIMARY KEY (lot_id, warehouse_id)
);

-- every change of stock is logged here (signed qty)
CREATE TABLE stock_move (
  id           bigserial PRIMARY KEY,
  product_id   int NOT NULL REFERENCES product(id),
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  lot_id       int REFERENCES lot(id),
  qty          numeric(14,3) NOT NULL,
  reason       text NOT NULL,   -- purchase, sale, pos, production_in, production_out, adjustment
  ref_type     text,
  ref_id       int,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- CRM ----------
CREATE TABLE crm_lead (
  id             serial PRIMARY KEY,
  title          text NOT NULL,
  partner_id     int REFERENCES partner(id),
  contact_name   text,
  email          text,
  phone          text,
  stage          text NOT NULL DEFAULT 'new' CHECK (stage IN ('new','qualified','proposal','won','lost')),
  expected_value numeric(12,2) NOT NULL DEFAULT 0,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE crm_activity (
  id         serial PRIMARY KEY,
  lead_id    int NOT NULL REFERENCES crm_lead(id) ON DELETE CASCADE,
  kind       text NOT NULL DEFAULT 'note' CHECK (kind IN ('call','email','meeting','note')),
  note       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Sales ----------
CREATE TABLE sales_order (
  id           serial PRIMARY KEY,
  number       text NOT NULL UNIQUE DEFAULT ('SO' || lpad(nextval('so_seq')::text, 5, '0')),
  partner_id   int NOT NULL REFERENCES partner(id),
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','delivered','cancelled')),
  order_date   date NOT NULL DEFAULT current_date,
  notes        text
);

CREATE TABLE sales_order_line (
  id           serial PRIMARY KEY,
  order_id     int NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
  product_id   int NOT NULL REFERENCES product(id),
  qty          numeric(14,3) NOT NULL CHECK (qty > 0),
  unit_price   numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  discount_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100)
);

-- ---------- Purchases ----------
CREATE TABLE purchase_order (
  id           serial PRIMARY KEY,
  number       text NOT NULL UNIQUE DEFAULT ('PO' || lpad(nextval('po_seq')::text, 5, '0')),
  partner_id   int NOT NULL REFERENCES partner(id),
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','received','cancelled')),
  order_date   date NOT NULL DEFAULT current_date,
  notes        text
);

CREATE TABLE purchase_order_line (
  id         serial PRIMARY KEY,
  order_id   int NOT NULL REFERENCES purchase_order(id) ON DELETE CASCADE,
  product_id int NOT NULL REFERENCES product(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),
  unit_cost  numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
  lot_no      text,            -- vendor's lot number (optional; one is generated when empty)
  expiry_date date
);

-- ---------- Invoicing & payments ----------
CREATE TABLE invoice (
  id                serial PRIMARY KEY,
  number            text NOT NULL UNIQUE DEFAULT ('INV' || lpad(nextval('inv_seq')::text, 5, '0')),
  kind              text NOT NULL CHECK (kind IN ('customer','vendor')),
  partner_id        int NOT NULL REFERENCES partner(id),
  sales_order_id    int UNIQUE REFERENCES sales_order(id),
  purchase_order_id int UNIQUE REFERENCES purchase_order(id),
  issue_date        date NOT NULL DEFAULT current_date,
  due_date          date NOT NULL DEFAULT current_date + 30,
  supply_type       text NOT NULL DEFAULT 'intra' CHECK (supply_type IN ('intra','inter')),
  place_of_supply   text,
  subtotal          numeric(14,2) NOT NULL DEFAULT 0,   -- taxable value
  cgst              numeric(14,2) NOT NULL DEFAULT 0,
  sgst              numeric(14,2) NOT NULL DEFAULT 0,
  igst              numeric(14,2) NOT NULL DEFAULT 0,
  round_off         numeric(6,2)  NOT NULL DEFAULT 0,
  total             numeric(14,2) NOT NULL CHECK (total >= 0),   -- amount payable, GST included
  paid              numeric(14,2) NOT NULL DEFAULT 0,
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','partial','paid'))
);

CREATE TABLE invoice_line (
  id            serial PRIMARY KEY,
  invoice_id    int NOT NULL REFERENCES invoice(id) ON DELETE CASCADE,
  product_id    int REFERENCES product(id),
  description   text NOT NULL,
  hsn_code      text,
  qty           numeric(14,3) NOT NULL,
  unit_price    numeric(12,2) NOT NULL,
  discount_pct  numeric(5,2) NOT NULL DEFAULT 0,
  taxable_value numeric(14,2) NOT NULL,
  gst_rate      numeric(5,2) NOT NULL,
  cgst          numeric(14,2) NOT NULL DEFAULT 0,
  sgst          numeric(14,2) NOT NULL DEFAULT 0,
  igst          numeric(14,2) NOT NULL DEFAULT 0,
  line_total    numeric(14,2) NOT NULL
);

CREATE TABLE payment (
  id         serial PRIMARY KEY,
  invoice_id int NOT NULL REFERENCES invoice(id) ON DELETE CASCADE,
  amount     numeric(14,2) NOT NULL CHECK (amount > 0),
  method     text NOT NULL DEFAULT 'bank' CHECK (method IN ('cash','bank','upi','card')),
  paid_at    timestamptz NOT NULL DEFAULT now(),
  note       text
);

-- ---------- Manufacturing ----------
CREATE TABLE bom (
  id         serial PRIMARY KEY,
  product_id int NOT NULL REFERENCES product(id),
  name       text NOT NULL,
  output_qty numeric(14,3) NOT NULL DEFAULT 1 CHECK (output_qty > 0)
);

CREATE TABLE bom_line (
  id           serial PRIMARY KEY,
  bom_id       int NOT NULL REFERENCES bom(id) ON DELETE CASCADE,
  component_id int NOT NULL REFERENCES product(id),
  qty          numeric(14,3) NOT NULL CHECK (qty > 0)
);

CREATE TABLE work_center (
  id          serial PRIMARY KEY,
  name        text NOT NULL UNIQUE,
  hourly_cost numeric(12,2) NOT NULL DEFAULT 0
);

CREATE TABLE production_order (
  id           serial PRIMARY KEY,
  number       text NOT NULL UNIQUE DEFAULT ('MO' || lpad(nextval('mo_seq')::text, 5, '0')),
  bom_id       int NOT NULL REFERENCES bom(id),
  qty          numeric(14,3) NOT NULL CHECK (qty > 0),
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  status       text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','in_progress','done','cancelled')),
  planned_date date NOT NULL DEFAULT current_date
);

CREATE TABLE work_order (
  id                  serial PRIMARY KEY,
  production_order_id int NOT NULL REFERENCES production_order(id) ON DELETE CASCADE,
  work_center_id      int NOT NULL REFERENCES work_center(id),
  operation           text NOT NULL,
  hours               numeric(8,2) NOT NULL DEFAULT 1 CHECK (hours >= 0),
  status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done'))
);

-- ---------- HR ----------
CREATE TABLE employee (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  email       text,
  phone       text,
  job_title   text,
  hourly_rate numeric(10,2) NOT NULL DEFAULT 0 CHECK (hourly_rate >= 0),
  hire_date   date NOT NULL DEFAULT current_date,
  active      boolean NOT NULL DEFAULT true
);

CREATE TABLE payslip (
  id           serial PRIMARY KEY,
  employee_id  int NOT NULL REFERENCES employee(id),
  period_start date NOT NULL,
  period_end   date NOT NULL,
  hours        numeric(10,2) NOT NULL,
  gross        numeric(12,2) NOT NULL,
  deductions   numeric(12,2) NOT NULL DEFAULT 0,
  net          numeric(12,2) NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end >= period_start)
);

-- ---------- Projects ----------
CREATE TABLE project (
  id         serial PRIMARY KEY,
  name       text NOT NULL,
  partner_id int REFERENCES partner(id),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active','on_hold','done')),
  start_date date NOT NULL DEFAULT current_date,
  deadline   date
);

CREATE TABLE task (
  id          serial PRIMARY KEY,
  project_id  int NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  title       text NOT NULL,
  employee_id int REFERENCES employee(id),
  status      text NOT NULL DEFAULT 'todo' CHECK (status IN ('todo','doing','done')),
  est_hours   numeric(8,2) NOT NULL DEFAULT 0
);

CREATE TABLE timesheet (
  id          serial PRIMARY KEY,
  task_id     int NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  employee_id int NOT NULL REFERENCES employee(id),
  work_date   date NOT NULL DEFAULT current_date,
  hours       numeric(6,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
  note        text
);

-- ---------- Point of Sale ----------
CREATE TABLE cash_register (
  id           serial PRIMARY KEY,
  name         text NOT NULL UNIQUE,
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  balance      numeric(14,2) NOT NULL DEFAULT 0,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed'))
);

CREATE TABLE pos_sale (
  id             serial PRIMARY KEY,
  number         text NOT NULL UNIQUE DEFAULT ('POS' || lpad(nextval('pos_seq')::text, 6, '0')),
  register_id    int NOT NULL REFERENCES cash_register(id),
  discount_pct   numeric(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
  total          numeric(14,2) NOT NULL DEFAULT 0,
  payment_method text NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','card','upi')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pos_sale_line (
  id         serial PRIMARY KEY,
  sale_id    int NOT NULL REFERENCES pos_sale(id) ON DELETE CASCADE,
  product_id int NOT NULL REFERENCES product(id),
  qty        numeric(14,3) NOT NULL CHECK (qty > 0),
  unit_price numeric(12,2) NOT NULL
);

-- ---------- Quotations ----------
CREATE TABLE quotation (
  id             serial PRIMARY KEY,
  number         text NOT NULL UNIQUE DEFAULT ('QT' || lpad(nextval('qt_seq')::text, 5, '0')),
  partner_id     int NOT NULL REFERENCES partner(id),
  lead_id        int REFERENCES crm_lead(id),
  quote_date     date NOT NULL DEFAULT current_date,
  valid_until    date NOT NULL DEFAULT current_date + 15,
  status         text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','accepted','rejected','converted')),
  sales_order_id int REFERENCES sales_order(id),
  notes          text,
  terms          text
);

CREATE TABLE quotation_line (
  id           serial PRIMARY KEY,
  quotation_id int NOT NULL REFERENCES quotation(id) ON DELETE CASCADE,
  product_id   int NOT NULL REFERENCES product(id),
  qty          numeric(14,3) NOT NULL CHECK (qty > 0),
  unit_price   numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  discount_pct numeric(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100)
);

-- ---------- Quality control ----------
CREATE TABLE qc_inspection (
  id                  serial PRIMARY KEY,
  number              text NOT NULL UNIQUE DEFAULT ('QC' || lpad(nextval('qc_seq')::text, 5, '0')),
  kind                text NOT NULL DEFAULT 'incoming' CHECK (kind IN ('incoming','in_process','final')),
  product_id          int NOT NULL REFERENCES product(id),
  lot_id              int REFERENCES lot(id),
  purchase_order_id   int REFERENCES purchase_order(id),
  production_order_id int REFERENCES production_order(id),
  inspected_on        date NOT NULL DEFAULT current_date,
  inspector_id        int REFERENCES employee(id),
  sample_size         numeric(10,2) NOT NULL DEFAULT 0 CHECK (sample_size >= 0),
  defects             numeric(10,2) NOT NULL DEFAULT 0 CHECK (defects >= 0),
  status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open','passed','failed')),
  disposition         text CHECK (disposition IN ('accept','rework','scrap','return_to_vendor')),
  rejection_reason    text,
  notes               text
);

CREATE TABLE qc_result (
  id            serial PRIMARY KEY,
  inspection_id int NOT NULL REFERENCES qc_inspection(id) ON DELETE CASCADE,
  parameter     text NOT NULL,          -- e.g. Bubble point, Micron rating, Dimensions
  unit          text,
  spec_min      numeric(14,4),
  spec_max      numeric(14,4),
  measured      numeric(14,4) NOT NULL,
  passed        boolean NOT NULL DEFAULT true
);

-- passed is worked out from the readings, never typed in
CREATE FUNCTION trg_qc_result_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.passed := (NEW.spec_min IS NULL OR NEW.measured >= NEW.spec_min)
            AND (NEW.spec_max IS NULL OR NEW.measured <= NEW.spec_max);
  RETURN NEW;
END $$;
CREATE TRIGGER qc_result_check BEFORE INSERT OR UPDATE ON qc_result
  FOR EACH ROW EXECUTE FUNCTION trg_qc_result_check();

-- changing lot tracking while stock exists would leave quantities without lots
CREATE FUNCTION trg_product_tracking_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tracked IS DISTINCT FROM OLD.tracked
     AND EXISTS (SELECT 1 FROM stock_quant WHERE product_id = OLD.id AND qty <> 0) THEN
    RAISE EXCEPTION 'Lot tracking cannot be changed while "%" still has stock', OLD.name;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER product_tracking_guard BEFORE UPDATE ON product
  FOR EACH ROW EXECUTE FUNCTION trg_product_tracking_guard();

-- ---------- Views used by the screens ----------
CREATE VIEW v_product AS
SELECT p.*, COALESCE(s.qty, 0) AS on_hand,
       (p.reorder_level > 0 AND COALESCE(s.qty, 0) <= p.reorder_level AND p.active) AS low_stock
FROM product p
LEFT JOIN (SELECT product_id, sum(qty) AS qty FROM stock_quant GROUP BY product_id) s ON s.product_id = p.id;

CREATE VIEW v_stock AS
SELECT q.product_id, p.sku, p.name AS product, q.warehouse_id, w.name AS warehouse, q.qty
FROM stock_quant q JOIN product p ON p.id = q.product_id JOIN warehouse w ON w.id = q.warehouse_id;

CREATE VIEW v_sales_order AS
SELECT o.*, t.total, t.tax, t.total + t.tax AS grand_total
FROM sales_order o
CROSS JOIN LATERAL (
  SELECT COALESCE(sum(round(l.qty * l.unit_price * (1 - l.discount_pct / 100), 2)), 0) AS total,
         COALESCE(sum(fn_gst_tax(round(l.qty * l.unit_price * (1 - l.discount_pct / 100), 2), p.gst_rate,
                  (SELECT pr.state_code IS NOT DISTINCT FROM c.state_code FROM partner pr, company c WHERE pr.id = o.partner_id))), 0) AS tax
  FROM sales_order_line l JOIN product p ON p.id = l.product_id WHERE l.order_id = o.id
) t;

CREATE VIEW v_purchase_order AS
SELECT o.*, t.total, t.tax, t.total + t.tax AS grand_total
FROM purchase_order o
CROSS JOIN LATERAL (
  SELECT COALESCE(sum(round(l.qty * l.unit_cost, 2)), 0) AS total,
         COALESCE(sum(fn_gst_tax(round(l.qty * l.unit_cost, 2), p.gst_rate,
                  (SELECT pr.state_code IS NOT DISTINCT FROM c.state_code FROM partner pr, company c WHERE pr.id = o.partner_id))), 0) AS tax
  FROM purchase_order_line l JOIN product p ON p.id = l.product_id WHERE l.order_id = o.id
) t;

CREATE VIEW v_quotation AS
SELECT q.*, t.total, t.tax, t.total + t.tax AS grand_total,
       (q.status IN ('draft','sent') AND q.valid_until < current_date) AS expired
FROM quotation q
CROSS JOIN LATERAL (
  SELECT COALESCE(sum(round(l.qty * l.unit_price * (1 - l.discount_pct / 100), 2)), 0) AS total,
         COALESCE(sum(fn_gst_tax(round(l.qty * l.unit_price * (1 - l.discount_pct / 100), 2), p.gst_rate,
                  (SELECT pr.state_code IS NOT DISTINCT FROM c.state_code FROM partner pr, company c WHERE pr.id = q.partner_id))), 0) AS tax
  FROM quotation_line l JOIN product p ON p.id = l.product_id WHERE l.quotation_id = q.id
) t;

CREATE VIEW v_invoice AS
SELECT i.*, i.total - i.paid AS balance,
       (i.status <> 'paid' AND i.due_date < current_date) AS overdue
FROM invoice i;

CREATE VIEW v_production_order AS
SELECT m.*, b.product_id, b.name AS bom_name
FROM production_order m JOIN bom b ON b.id = m.bom_id;

CREATE VIEW v_project AS
SELECT p.*,
       (SELECT count(*) FROM task t WHERE t.project_id = p.id) AS tasks,
       (SELECT count(*) FROM task t WHERE t.project_id = p.id AND t.status = 'done') AS tasks_done,
       COALESCE((SELECT sum(ts.hours) FROM timesheet ts JOIN task t ON t.id = ts.task_id WHERE t.project_id = p.id), 0) AS hours_logged
FROM project p;

CREATE VIEW v_timesheet AS
SELECT ts.*, t.project_id, t.title AS task_title
FROM timesheet ts JOIN task t ON t.id = ts.task_id;

CREATE INDEX ON stock_move (product_id, created_at DESC);
CREATE INDEX ON sales_order_line (order_id);
CREATE INDEX ON purchase_order_line (order_id);
CREATE INDEX ON timesheet (employee_id, work_date);
CREATE INDEX ON payment (invoice_id);

-- ---------- Reports ----------
-- Cost of a manufactured product = material cost from its bill of materials; bought items use their purchase cost.
CREATE VIEW v_costing AS
SELECT p.id, p.sku, p.name, p.price, b.id AS bom_id,
       CASE WHEN b.id IS NULL THEN p.cost
            ELSE round(COALESCE((SELECT sum(c.cost * bl.qty) FROM bom_line bl JOIN product c ON c.id = bl.component_id
                                  WHERE bl.bom_id = b.id), 0) / b.output_qty, 2) END AS unit_cost,
       p.price - CASE WHEN b.id IS NULL THEN p.cost
            ELSE round(COALESCE((SELECT sum(c.cost * bl.qty) FROM bom_line bl JOIN product c ON c.id = bl.component_id
                                  WHERE bl.bom_id = b.id), 0) / b.output_qty, 2) END AS margin,
       CASE WHEN p.price > 0 THEN round(100 * (p.price - CASE WHEN b.id IS NULL THEN p.cost
            ELSE round(COALESCE((SELECT sum(c.cost * bl.qty) FROM bom_line bl JOIN product c ON c.id = bl.component_id
                                  WHERE bl.bom_id = b.id), 0) / b.output_qty, 2) END) / p.price, 1) END AS margin_pct
FROM product p
LEFT JOIN LATERAL (SELECT * FROM bom WHERE product_id = p.id ORDER BY id LIMIT 1) b ON true
WHERE p.price > 0 AND p.active;

-- Money customers owe us, grouped by how late it is
CREATE VIEW v_ageing AS
SELECT partner_id,
       COALESCE(sum(CASE WHEN due_date >= current_date THEN balance END), 0)                          AS not_due,
       COALESCE(sum(CASE WHEN current_date - due_date BETWEEN 1 AND 30 THEN balance END), 0)          AS d1_30,
       COALESCE(sum(CASE WHEN current_date - due_date BETWEEN 31 AND 60 THEN balance END), 0)         AS d31_60,
       COALESCE(sum(CASE WHEN current_date - due_date > 60 THEN balance END), 0)                      AS d61_plus,
       sum(balance)                                                                                   AS total
FROM (SELECT partner_id, due_date, total - paid AS balance FROM invoice WHERE kind = 'customer' AND status <> 'paid') i
GROUP BY partner_id;

-- Low-stock products that are not already on an open purchase order
CREATE VIEW v_reorder AS
SELECT p.id, p.sku, p.name, p.vendor_id, p.on_hand, p.reorder_level,
       CASE WHEN p.reorder_qty > 0 THEN p.reorder_qty ELSE GREATEST(p.reorder_level * 2 - p.on_hand, 1) END AS suggested_qty
FROM v_product p
WHERE p.low_stock
  AND NOT EXISTS (SELECT 1 FROM purchase_order_line l JOIN purchase_order o ON o.id = l.order_id
                   WHERE l.product_id = p.id AND o.status IN ('draft','confirmed'));

-- ---------- Users, roles and audit trail ----------
CREATE TABLE app_user (
  id            serial PRIMARY KEY,
  username      text NOT NULL UNIQUE CHECK (username = lower(username) AND length(username) >= 3),
  full_name     text,
  role          text NOT NULL CHECK (role IN ('admin','sales','store','accounts','hr','cashier','viewer')),
  password_hash text NOT NULL,
  must_change   boolean NOT NULL DEFAULT true,   -- a new or reset password must be replaced at the next sign-in
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
  id       bigserial PRIMARY KEY,
  at       timestamptz NOT NULL DEFAULT now(),
  username text NOT NULL,
  action   text NOT NULL,   -- e.g. POST, PUT, DELETE, ACTION
  target   text NOT NULL    -- e.g. sales_order/5 or fn_so_deliver
);
CREATE INDEX ON audit_log (at DESC);

-- the password hash never leaves the database
CREATE VIEW v_app_user AS SELECT id, username, full_name, role, active, created_at FROM app_user;   -- never exposes password hashes
-- names only, so people without HR access can still see who a task is assigned to
CREATE VIEW v_staff AS SELECT id, name, job_title, active FROM employee;

-- ---------- Lots, traceability and QC views ----------
CREATE VIEW v_lot AS
SELECT l.*, p.sku, p.name AS product,
       COALESCE((SELECT sum(qty) FROM lot_quant q WHERE q.lot_id = l.id), 0) AS on_hand,
       l.expiry_date - current_date AS days_to_expiry,
       CASE WHEN l.quality_status = 'rejected' THEN 'rejected'
            WHEN l.expiry_date IS NOT NULL AND l.expiry_date < current_date THEN 'expired'
            WHEN l.expiry_date IS NOT NULL AND l.expiry_date - current_date <= 30 THEN 'expiring'
            ELSE 'ok' END AS state
FROM lot l JOIN product p ON p.id = l.product_id;

CREATE VIEW v_stock_move AS
SELECT m.*, l.lot_no,
       CASE m.ref_type
         WHEN 'sales_order'      THEN (SELECT o.number || ' · ' || pr.name FROM sales_order o JOIN partner pr ON pr.id = o.partner_id WHERE o.id = m.ref_id)
         WHEN 'purchase_order'   THEN (SELECT o.number || ' · ' || pr.name FROM purchase_order o JOIN partner pr ON pr.id = o.partner_id WHERE o.id = m.ref_id)
         WHEN 'production_order' THEN (SELECT number FROM production_order WHERE id = m.ref_id)
         WHEN 'pos_sale'         THEN (SELECT number FROM pos_sale WHERE id = m.ref_id)
       END AS reference
FROM stock_move m LEFT JOIN lot l ON l.id = m.lot_id;

-- Full history of a lot: every movement, what it was made from and what it was used for
CREATE VIEW v_lot_trace AS
SELECT row_number() OVER (ORDER BY at, k) AS id, lot_id, at, event, qty, party, reference
FROM (
  SELECT m.lot_id, m.created_at AS at, 1 AS k, replace(m.reason, '_', ' ') AS event, m.qty,
         CASE m.ref_type
           WHEN 'sales_order'    THEN (SELECT pr.name FROM sales_order o JOIN partner pr ON pr.id = o.partner_id WHERE o.id = m.ref_id)
           WHEN 'purchase_order' THEN (SELECT pr.name FROM purchase_order o JOIN partner pr ON pr.id = o.partner_id WHERE o.id = m.ref_id)
         END AS party,
         v.reference
  FROM stock_move m JOIN v_stock_move v ON v.id = m.id
  WHERE m.lot_id IS NOT NULL
  UNION ALL   -- finished lot: which component lots went into it
  SELECT fin.lot_id, fin.created_at, 2, 'made from', -c.qty, NULL,
         'lot ' || cl.lot_no || ' (' || cp.name || ')'
  FROM stock_move fin
  JOIN stock_move c ON c.ref_type = fin.ref_type AND c.ref_id = fin.ref_id AND c.reason = 'production_out' AND c.lot_id IS NOT NULL
  JOIN lot cl ON cl.id = c.lot_id JOIN product cp ON cp.id = cl.product_id
  WHERE fin.reason = 'production_in' AND fin.lot_id IS NOT NULL
  UNION ALL   -- component lot: which finished lots it ended up in
  SELECT c.lot_id, c.created_at, 3, 'used to make', -c.qty, NULL,
         'lot ' || fl.lot_no || ' (' || fp.name || ')'
  FROM stock_move c
  JOIN stock_move fin ON fin.ref_type = c.ref_type AND fin.ref_id = c.ref_id AND fin.reason = 'production_in' AND fin.lot_id IS NOT NULL
  JOIN lot fl ON fl.id = fin.lot_id JOIN product fp ON fp.id = fl.product_id
  WHERE c.reason = 'production_out' AND c.lot_id IS NOT NULL
) t;

CREATE VIEW v_qc_inspection AS
SELECT q.*, l.lot_no,
       (SELECT count(*) FROM qc_result r WHERE r.inspection_id = q.id) AS tests,
       (SELECT count(*) FROM qc_result r WHERE r.inspection_id = q.id AND NOT r.passed) AS tests_failed,
       CASE WHEN q.sample_size > 0 THEN round(100 * q.defects / q.sample_size, 1) END AS defect_pct
FROM qc_inspection q LEFT JOIN lot l ON l.id = q.lot_id;
