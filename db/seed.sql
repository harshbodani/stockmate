-- StockMate: demo data (filtration business). Safe to skip in production.

INSERT INTO warehouse (name, location) VALUES
  ('Main Warehouse', 'Ahmedabad'),
  ('Production Store', 'Factory floor');

INSERT INTO partner (name, kind, email, phone, address) VALUES
  ('Aqua Pure Traders',    'customer', 'orders@aquapure.example', '+91 90000 00001', 'Ahmedabad'),
  ('Shree Engineering',    'customer', 'buy@shreeeng.example',    '+91 90000 00002', 'Rajkot'),
  ('Navkar Auto Parts',    'customer', 'info@navkar.example',     '+91 90000 00003', 'Surat'),
  ('Polyfab Media Supply', 'vendor',   'sales@polyfab.example',   '+91 90000 00004', 'Vapi'),
  ('Rubber & Seal Co.',    'vendor',   'hello@rubberseal.example','+91 90000 00005', 'Vadodara'),
  ('FiltroParts Components','vendor',   'sales@filtroparts.example','+91 90000 00006', 'Ahmedabad');

INSERT INTO product (sku, barcode, name, category, unit, cost, price, reorder_level, reorder_qty, vendor_id, micron, size, material, flow_rate, fits_models) VALUES
  ('FM-001', '8900000000011', 'Filter Media Roll (50 m)',    'Raw material', 'roll', 600, 0,    5,   10,  4, 5,    '50 m roll',  'Melt-blown polypropylene', NULL,       NULL),
  ('EC-001', '8900000000028', 'Polypropylene End Cap',       'Raw material', 'pcs',  6,   0,    100, 500, 4, NULL, NULL,         'Polypropylene',            NULL,       NULL),
  ('AD-001', '8900000000035', 'Adhesive Tube',               'Raw material', 'pcs',  45,  0,    20,  0,   4, NULL, NULL,         'Hot-melt adhesive',        NULL,       NULL),
  ('CT-100', '8900000000042', 'Water Filter Cartridge 10"',  'Finished',     'pcs',  0,   180,  30,  0,   NULL, 5, '10 inch',    'Polypropylene',            '500 LPH',  'HS-400, standard 10 inch RO housings'),
  ('OF-200', '8900000000059', 'Oil Filter Element',          'Finished',     'pcs',  90,  210,  25,  0,   6, 20, '120 mm',    'Cellulose',                NULL,       'Diesel generators, light trucks'),
  ('AF-300', '8900000000066', 'Air Filter Panel',            'Finished',     'pcs',  120, 260,  25,  0,   6, 10, '300 x 300 mm', 'Synthetic fibre',       NULL,       'Compressors, AHU units'),
  ('HS-400', '8900000000073', 'Filter Housing 10"',          'Finished',     'pcs',  350, 690,  10,  0,   NULL, NULL, '10 inch',  'Polypropylene',            '1000 LPH', 'Takes CT-100 cartridges'),
  ('GK-500', '8900000000080', 'Rubber Gasket Set',           'Spare',        'set',  20,  55,   50,  100, 5, NULL, NULL,         'Nitrile rubber',           NULL,       'HS-400 housings');

INSERT INTO employee (name, email, phone, job_title, hourly_rate, hire_date) VALUES
  ('Ravi Patel',   'ravi@filtsap.example',   '+91 91000 00001', 'Production Supervisor', 220, '2024-06-01'),
  ('Meena Shah',   'meena@filtsap.example',  '+91 91000 00002', 'Sales Executive',       200, '2025-01-15'),
  ('Kiran Joshi',  'kiran@filtsap.example',  '+91 91000 00003', 'Store Keeper',          160, '2025-03-10');

INSERT INTO work_center (name, hourly_cost) VALUES ('Assembly Line', 150), ('Quality Check', 90);

INSERT INTO cash_register (name, warehouse_id, balance) VALUES ('Counter 1', 1, 5000);

-- opening stock
SELECT fn_adjust_stock('{"product_id":1,"warehouse_id":2,"qty":12}');
SELECT fn_adjust_stock('{"product_id":2,"warehouse_id":2,"qty":900}');
SELECT fn_adjust_stock('{"product_id":3,"warehouse_id":2,"qty":60}');
SELECT fn_adjust_stock('{"product_id":4,"warehouse_id":1,"qty":80}');
SELECT fn_adjust_stock('{"product_id":5,"warehouse_id":1,"qty":18}');
SELECT fn_adjust_stock('{"product_id":6,"warehouse_id":1,"qty":40}');
SELECT fn_adjust_stock('{"product_id":7,"warehouse_id":1,"qty":14}');
SELECT fn_adjust_stock('{"product_id":8,"warehouse_id":1,"qty":120}');

-- bill of materials: 1 cartridge = 0.1 roll of media + 2 end caps + 1 adhesive tube
INSERT INTO bom (product_id, name, output_qty) VALUES (4, 'Water Filter Cartridge 10"', 1);
INSERT INTO bom_line (bom_id, component_id, qty) VALUES (1, 1, 0.1), (1, 2, 2), (1, 3, 1);

-- CRM
INSERT INTO crm_lead (title, contact_name, email, phone, stage, expected_value, notes) VALUES
  ('RO plant cartridges - Zenith Foods', 'Anil Mehta',  'anil@zenith.example',  '+91 92000 00001', 'qualified', 85000,  'Needs monthly supply'),
  ('Housing + element bulk order',       'Pooja Desai', 'pooja@desai.example',  '+91 92000 00002', 'proposal',  240000, 'Quote sent'),
  ('Dealer enquiry - Vadodara',          'S. Parmar',   NULL,                   '+91 92000 00003', 'new',       30000,  NULL);
INSERT INTO crm_activity (lead_id, kind, note) VALUES
  (1, 'call', 'Discussed monthly requirement of 300 cartridges'),
  (2, 'email', 'Sent quotation Q-102');

-- a purchase: confirm, receive, invoice
INSERT INTO purchase_order (partner_id, warehouse_id) VALUES (4, 2);
INSERT INTO purchase_order_line (order_id, product_id, qty, unit_cost) VALUES (1, 1, 6, 580), (1, 3, 40, 44);
SELECT fn_po_confirm('{"id":1}');
SELECT fn_po_receive('{"id":1}');
SELECT fn_create_invoice('{"kind":"purchase","order_id":1}');

-- a sale: confirm, deliver, invoice, part-payment
INSERT INTO sales_order (partner_id, warehouse_id) VALUES (1, 1);
INSERT INTO sales_order_line (order_id, product_id, qty, unit_price, discount_pct) VALUES
  (1, 4, 20, 180, 5), (1, 8, 10, 55, 0);
SELECT fn_so_confirm('{"id":1}');
SELECT fn_so_deliver('{"id":1}');
SELECT fn_create_invoice('{"kind":"sales","order_id":1,"due_days":15}');
INSERT INTO payment (invoice_id, amount, method) VALUES (2, 2000, 'bank');

-- a draft sale and a planned production order
INSERT INTO sales_order (partner_id, warehouse_id) VALUES (2, 1);
INSERT INTO sales_order_line (order_id, product_id, qty, unit_price) VALUES (2, 7, 5, 690), (2, 5, 10, 210);
INSERT INTO production_order (bom_id, qty, warehouse_id) VALUES (1, 40, 2);
INSERT INTO work_order (production_order_id, work_center_id, operation, hours) VALUES
  (1, 1, 'Wind and assemble cartridges', 6), (1, 2, 'Pressure test', 2);

-- project, tasks and timesheets
INSERT INTO project (name, partner_id, deadline) VALUES ('Zenith Foods - filtration line setup', NULL, current_date + 30);
INSERT INTO task (project_id, title, employee_id, status, est_hours) VALUES
  (1, 'Site survey',        1, 'done',  8),
  (1, 'Prepare quotation',  2, 'doing', 6),
  (1, 'Install housings',   3, 'todo',  16);
INSERT INTO timesheet (task_id, employee_id, work_date, hours, note) VALUES
  (1, 1, current_date - 5, 7.5, 'Site visit'),
  (2, 2, current_date - 2, 4,   'Costing sheet'),
  (2, 2, current_date - 1, 3,   NULL);

-- a POS sale
SELECT fn_pos_checkout('{"register_id":1,"items":[{"barcode":"8900000000080","qty":2},{"barcode":"8900000000059","qty":1}],"method":"cash"}');

-- an old unpaid invoice so the ageing report has something to show
INSERT INTO sales_order (partner_id, warehouse_id) VALUES (3, 1);
INSERT INTO sales_order_line (order_id, product_id, qty, unit_price) VALUES (3, 6, 10, 260);
SELECT fn_so_confirm('{"id":3}');
SELECT fn_so_deliver('{"id":3}');
SELECT fn_create_invoice('{"kind":"sales","order_id":3}');
UPDATE invoice SET issue_date = current_date - 75, due_date = current_date - 45 WHERE sales_order_id = 3;
