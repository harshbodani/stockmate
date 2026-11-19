-- StockMate: database schema (PostgreSQL 14+)
-- Modules: Core/Stock, CRM, Sales, Purchases, Invoicing, Manufacturing, Projects, HR, POS

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- password hashing (bcrypt)

CREATE SEQUENCE so_seq;
CREATE SEQUENCE po_seq;
CREATE SEQUENCE inv_seq;
CREATE SEQUENCE mo_seq;
CREATE SEQUENCE pos_seq;

-- ---------- Core: partners, warehouses, products ----------
CREATE TABLE partner (
  id         serial PRIMARY KEY,
  name       text NOT NULL,
  kind       text NOT NULL DEFAULT 'customer' CHECK (kind IN ('customer','vendor','both')),
  email      text,
  phone      text,
  address    text,
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
  reorder_qty   numeric(14,3) NOT NULL DEFAULT 0   -- usual order quantity (0 = automatic suggestion)
);

-- current stock per product per warehouse
CREATE TABLE stock_quant (
  product_id   int NOT NULL REFERENCES product(id) ON DELETE CASCADE,
  warehouse_id int NOT NULL REFERENCES warehouse(id),
  qty          numeric(14,3) NOT NULL DEFAULT 0 CHECK (qty >= 0),
  PRIMARY KEY (product_id, warehouse_id)
);

-- every change of stock is logged here (signed qty)
CREATE TABLE stock_move (
  id           bigserial PRIMARY KEY,
  product_id   int NOT NULL REFERENCES product(id),
  warehouse_id int NOT NULL REFERENCES warehouse(id),
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
  unit_cost  numeric(12,2) NOT NULL CHECK (unit_cost >= 0)
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
  total             numeric(14,2) NOT NULL CHECK (total >= 0),
  paid              numeric(14,2) NOT NULL DEFAULT 0,
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','partial','paid'))
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
SELECT o.*, COALESCE((SELECT round(sum(l.qty * l.unit_price * (1 - l.discount_pct / 100)), 2)
                      FROM sales_order_line l WHERE l.order_id = o.id), 0) AS total
FROM sales_order o;

CREATE VIEW v_purchase_order AS
SELECT o.*, COALESCE((SELECT round(sum(l.qty * l.unit_cost), 2)
                      FROM purchase_order_line l WHERE l.order_id = o.id), 0) AS total
FROM purchase_order o;

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
CREATE VIEW v_app_user AS SELECT id, username, full_name, role, active, created_at FROM app_user;
-- names only, so people without HR access can still see who a task is assigned to
CREATE VIEW v_staff AS SELECT id, name, job_title, active FROM employee;
