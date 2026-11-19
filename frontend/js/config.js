/*
 * StockMate screen definitions.
 * Each entity describes one table: its fields, which columns to list, and which buttons it has.
 * Field types: text, number, date, select, ref (points at another entity), textarea, bool.
 * Flags:  req = required, ro = shown only (computed/system), m = money, badge = coloured status pill.
 */

// How a record of each entity is named when another screen refers to it.
const LABEL = {
  partner: r => r.name,
  warehouse: r => r.name,
  product: r => `${r.sku} · ${r.name}`,
  employee: r => r.name,
  sales_order: r => r.number,
  purchase_order: r => r.number,
  production_order: r => r.number,
  invoice: r => r.number,
  bom: r => r.name,
  work_center: r => r.name,
  project: r => r.name,
  task: r => r.title,
  cash_register: r => r.name,
  crm_lead: r => r.title,
  staff: r => r.name,
  app_user: r => `${r.username} (${r.role})`,
};

const STATUS_OPTS = {
  order: ['draft', 'confirmed', 'delivered', 'cancelled'],
};

const F = {
  // shorthand builders
  text: (k, l, o = {}) => ({ k, l, t: 'text', ...o }),
  area: (k, l, o = {}) => ({ k, l, t: 'textarea', ...o }),
  num: (k, l, o = {}) => ({ k, l, t: 'number', ...o }),
  money: (k, l, o = {}) => ({ k, l, t: 'number', m: true, step: '0.01', ...o }),
  date: (k, l, o = {}) => ({ k, l, t: 'date', ...o }),
  sel: (k, l, opts, o = {}) => ({ k, l, t: 'select', opts, ...o }),
  ref: (k, l, ref, o = {}) => ({ k, l, t: 'ref', ref, ...o }),
  bool: (k, l, o = {}) => ({ k, l, t: 'bool', ...o }),
  pass: (k, l, o = {}) => ({ k, l, t: 'password', ...o }),
};

const ENTITIES = {
  partner: {
    title: 'Partners', single: 'Partner',
    fields: [F.text('name', 'Name', { req: 1 }), F.sel('kind', 'Type', ['customer', 'vendor', 'both']),
             F.text('email', 'Email'), F.text('phone', 'Phone'), F.area('address', 'Address')],
    cols: ['name', 'kind', 'email', 'phone'],
  },

  warehouse: {
    title: 'Warehouses', single: 'Warehouse',
    fields: [F.text('name', 'Name', { req: 1 }), F.text('location', 'Location')],
    cols: ['name', 'location'],
  },

  product: {
    title: 'Products', single: 'Product',
    fields: [F.text('sku', 'SKU', { req: 1 }), F.text('barcode', 'Barcode'), F.text('name', 'Name', { req: 1 }),
             F.text('category', 'Category'), F.text('unit', 'Unit'),
             F.num('micron', 'Micron rating', { step: '0.01' }), F.text('size', 'Size'), F.text('material', 'Material'),
             F.text('flow_rate', 'Flow rate'), F.area('fits_models', 'Fits / compatible with'),
             F.money('cost', 'Cost'), F.money('price', 'Sale price'),
             F.num('reorder_level', 'Reorder level'), F.num('reorder_qty', 'Usual reorder quantity (0 = automatic)'),
             F.ref('vendor_id', 'Preferred vendor', 'partner'), F.bool('active', 'Active'),
             { k: 'on_hand', l: 'On hand', t: 'number', ro: 1,
               fmt: r => ({ text: fmtNum(r.on_hand), cls: r.low_stock ? 'low' : '' }) }],
    cols: ['sku', 'name', 'micron', 'size', 'fits_models', 'on_hand', 'cost', 'price'],
  },

  stock: {
    title: 'Stock by warehouse', readonly: true,
    fields: [F.text('sku', 'SKU'), F.text('product', 'Product'), F.text('warehouse', 'Warehouse'), F.num('qty', 'Quantity')],
    cols: ['sku', 'product', 'warehouse', 'qty'],
    toolbar: [{
      label: 'Adjust stock', fn: 'fn_adjust_stock', done: 'Stock adjusted',
      fields: [F.ref('product_id', 'Product', 'product', { req: 1 }), F.ref('warehouse_id', 'Warehouse', 'warehouse', { req: 1 }),
               F.num('qty', 'Quantity (use a minus sign to remove stock)', { req: 1, step: 'any' })],
    }, {
      label: 'Transfer stock', fn: 'fn_transfer_stock', done: 'Stock transferred',
      fields: [F.ref('product_id', 'Product', 'product', { req: 1 }), F.ref('from_warehouse_id', 'From warehouse', 'warehouse', { req: 1 }),
               F.ref('to_warehouse_id', 'To warehouse', 'warehouse', { req: 1 }), F.num('qty', 'Quantity', { req: 1, step: 'any' })],
    }],
  },

  stock_move: {
    title: 'Stock movements', readonly: true,
    fields: [{ k: 'created_at', l: 'When', t: 'datetime' }, F.ref('product_id', 'Product', 'product'),
             F.ref('warehouse_id', 'Warehouse', 'warehouse'), F.num('qty', 'Qty'), F.text('reason', 'Reason', { badge: 1 })],
    cols: ['created_at', 'product_id', 'warehouse_id', 'qty', 'reason'],
  },

  // ---------------- Sales & CRM
  crm_lead: {
    title: 'Leads', single: 'Lead',
    fields: [F.text('title', 'Lead', { req: 1 }), F.ref('partner_id', 'Customer', 'partner'),
             F.text('contact_name', 'Contact'), F.text('email', 'Email'), F.text('phone', 'Phone'),
             F.sel('stage', 'Stage', ['new', 'qualified', 'proposal', 'won', 'lost'], { badge: 1 }),
             F.money('expected_value', 'Expected value'), F.area('notes', 'Notes')],
    cols: ['title', 'contact_name', 'stage', 'expected_value'],
    detail: { child: 'crm_activity', fk: 'lead_id', title: 'Communication history' },
    actions: [{ label: 'Convert to customer', fn: 'fn_crm_convert', show: r => !['won', 'lost'].includes(r.stage),
                done: 'Lead converted to a customer', confirm: 'Create a customer from this lead and mark it won?' }],
  },

  crm_activity: {
    title: 'Activities', single: 'Activity',
    fields: [F.sel('kind', 'Type', ['call', 'email', 'meeting', 'note']), F.area('note', 'Note', { req: 1 }),
             { k: 'created_at', l: 'When', t: 'datetime', ro: 1 }],
    cols: ['created_at', 'kind', 'note'],
  },

  sales_order: {
    title: 'Sales orders', single: 'Sales order',
    fields: [F.text('number', 'Number', { ro: 1 }), F.ref('partner_id', 'Customer', 'partner', { req: 1 }),
             F.ref('warehouse_id', 'Ship from', 'warehouse', { req: 1 }), F.date('order_date', 'Order date'),
             F.area('notes', 'Notes'), F.text('status', 'Status', { ro: 1, badge: 1 }), F.money('total', 'Total', { ro: 1 })],
    cols: ['number', 'partner_id', 'order_date', 'status', 'total'],
    editable: r => r.status === 'draft',
    detail: { child: 'sales_order_line', fk: 'order_id', title: 'Order lines', editable: p => p.status === 'draft' },
    actions: [
      { label: 'Confirm', fn: 'fn_so_confirm', show: r => r.status === 'draft', done: 'Order confirmed' },
      { label: 'Deliver', fn: 'fn_so_deliver', show: r => r.status === 'confirmed', done: 'Delivered, stock updated',
        confirm: 'Deliver this order? Stock will be reduced.' },
      { label: 'Create invoice', fn: 'fn_create_invoice', show: r => ['confirmed', 'delivered'].includes(r.status),
        body: r => ({ kind: 'sales', order_id: r.id }), done: 'Invoice created', link: 'invoice' },
      { label: 'Cancel', fn: 'fn_so_cancel', show: r => ['draft', 'confirmed'].includes(r.status), danger: 1,
        confirm: 'Cancel this order?', done: 'Order cancelled' },
    ],
  },

  sales_order_line: {
    title: 'Order lines', single: 'Line',
    fields: [F.ref('product_id', 'Product', 'product', { req: 1 }), F.num('qty', 'Quantity', { req: 1, step: 'any' }),
             F.money('unit_price', 'Unit price', { req: 1, fillFrom: { src: 'product_id', prop: 'price' } }),
             F.num('discount_pct', 'Discount %', { step: '0.01' }),
             { k: 'line_total', l: 'Line total', t: 'number', ro: 1, m: 1,
               fmt: r => ({ text: fmtMoney(r.qty * r.unit_price * (1 - (r.discount_pct || 0) / 100)) }) }],
    cols: ['product_id', 'qty', 'unit_price', 'discount_pct', 'line_total'],
  },

  // ---------------- Purchases & Stock
  purchase_order: {
    title: 'Purchase orders', single: 'Purchase order',
    fields: [F.text('number', 'Number', { ro: 1 }), F.ref('partner_id', 'Vendor', 'partner', { req: 1 }),
             F.ref('warehouse_id', 'Deliver to', 'warehouse', { req: 1 }), F.date('order_date', 'Order date'),
             F.area('notes', 'Notes'), F.text('status', 'Status', { ro: 1, badge: 1 }), F.money('total', 'Total', { ro: 1 })],
    cols: ['number', 'partner_id', 'order_date', 'status', 'total'],
    editable: r => r.status === 'draft',
    detail: { child: 'purchase_order_line', fk: 'order_id', title: 'Order lines', editable: p => p.status === 'draft' },
    actions: [
      { label: 'Confirm', fn: 'fn_po_confirm', show: r => r.status === 'draft', done: 'Order confirmed' },
      { label: 'Receive goods', fn: 'fn_po_receive', show: r => r.status === 'confirmed', done: 'Goods received, stock updated',
        confirm: 'Receive all lines into the warehouse?' },
      { label: 'Create invoice', fn: 'fn_create_invoice', show: r => ['confirmed', 'received'].includes(r.status),
        body: r => ({ kind: 'purchase', order_id: r.id }), done: 'Vendor bill created', link: 'invoice' },
      { label: 'Cancel', fn: 'fn_po_cancel', show: r => ['draft', 'confirmed'].includes(r.status), danger: 1,
        confirm: 'Cancel this order?', done: 'Order cancelled' },
    ],
  },

  purchase_order_line: {
    title: 'Order lines', single: 'Line',
    fields: [F.ref('product_id', 'Product', 'product', { req: 1 }), F.num('qty', 'Quantity', { req: 1, step: 'any' }),
             F.money('unit_cost', 'Unit cost', { req: 1, fillFrom: { src: 'product_id', prop: 'cost' } }),
             { k: 'line_total', l: 'Line total', t: 'number', ro: 1, m: 1, fmt: r => ({ text: fmtMoney(r.qty * r.unit_cost) }) }],
    cols: ['product_id', 'qty', 'unit_cost', 'line_total'],
  },

  // ---------------- Invoicing
  invoice: {
    title: 'Invoices & payments', single: 'Invoice', readonly: true,
    fields: [F.text('number', 'Number'), F.text('kind', 'Type', { badge: 1 }), F.ref('partner_id', 'Partner', 'partner'),
             F.date('issue_date', 'Issued'), F.date('due_date', 'Due'), F.money('total', 'Total'), F.money('paid', 'Paid'),
             F.money('balance', 'Balance'), F.text('status', 'Status', { badge: 1 }),
             { k: 'overdue', l: 'Overdue', t: 'bool', ro: 1 }],
    cols: ['number', 'kind', 'partner_id', 'due_date', 'total', 'paid', 'status'],
    rowClass: r => (r.overdue ? 'overdue' : ''),
    detail: { child: 'payment', fk: 'invoice_id', title: 'Payments', editable: p => p.status !== 'paid', noEdit: true },
  },

  payment: {
    title: 'Payments', single: 'Payment',
    fields: [F.money('amount', 'Amount', { req: 1 }), F.sel('method', 'Method', ['bank', 'cash', 'upi', 'card']),
             F.text('note', 'Note'), { k: 'paid_at', l: 'Paid on', t: 'datetime', ro: 1 }],
    cols: ['paid_at', 'amount', 'method', 'note'],
  },

  // ---------------- Manufacturing
  bom: {
    title: 'Bills of materials', single: 'Bill of materials',
    fields: [F.ref('product_id', 'Finished product', 'product', { req: 1 }), F.text('name', 'Name', { req: 1 }),
             F.num('output_qty', 'Makes (qty)', { step: 'any' })],
    cols: ['name', 'product_id', 'output_qty'],
    detail: { child: 'bom_line', fk: 'bom_id', title: 'Components' },
  },

  bom_line: {
    title: 'Components', single: 'Component',
    fields: [F.ref('component_id', 'Component', 'product', { req: 1 }), F.num('qty', 'Quantity', { req: 1, step: 'any' })],
    cols: ['component_id', 'qty'],
  },

  work_center: {
    title: 'Work centers', single: 'Work center',
    fields: [F.text('name', 'Name', { req: 1 }), F.money('hourly_cost', 'Hourly cost')],
    cols: ['name', 'hourly_cost'],
  },

  production_order: {
    title: 'Production orders', single: 'Production order',
    fields: [F.text('number', 'Number', { ro: 1 }), F.ref('bom_id', 'Bill of materials', 'bom', { req: 1 }),
             F.num('qty', 'Quantity to make', { req: 1, step: 'any' }), F.ref('warehouse_id', 'Warehouse', 'warehouse', { req: 1 }),
             F.date('planned_date', 'Planned date'), F.text('status', 'Status', { ro: 1, badge: 1 })],
    cols: ['number', 'bom_id', 'qty', 'planned_date', 'status'],
    editable: r => r.status === 'planned',
    detail: { child: 'work_order', fk: 'production_order_id', title: 'Work orders', editable: p => ['planned', 'in_progress'].includes(p.status) },
    actions: [
      { label: 'Start', fn: 'fn_mo_start', show: r => r.status === 'planned', done: 'Production started' },
      { label: 'Complete', fn: 'fn_mo_complete', show: r => ['planned', 'in_progress'].includes(r.status),
        confirm: 'Complete production? Components will be consumed and finished goods added to stock.', done: 'Production complete, stock updated' },
      { label: 'Cancel', fn: 'fn_mo_cancel', show: r => ['planned', 'in_progress'].includes(r.status), danger: 1,
        confirm: 'Cancel this production order?', done: 'Cancelled' },
    ],
  },

  work_order: {
    title: 'Work orders', single: 'Work order',
    fields: [F.ref('work_center_id', 'Work center', 'work_center', { req: 1 }), F.text('operation', 'Operation', { req: 1 }),
             F.num('hours', 'Hours', { step: '0.25' }), F.text('status', 'Status', { ro: 1, badge: 1 })],
    cols: ['operation', 'work_center_id', 'hours', 'status'],
  },

  // ---------------- Projects
  project: {
    title: 'Projects', single: 'Project',
    fields: [F.text('name', 'Name', { req: 1 }), F.ref('partner_id', 'Customer', 'partner'),
             F.sel('status', 'Status', ['active', 'on_hold', 'done'], { badge: 1 }),
             F.date('start_date', 'Start'), F.date('deadline', 'Deadline', { nodef: 1 }),
             { k: 'progress', l: 'Progress', t: 'text', ro: 1,
               fmt: r => ({ text: `${r.tasks_done}/${r.tasks} tasks · ${fmtNum(r.hours_logged)} h logged` }) }],
    cols: ['name', 'partner_id', 'status', 'deadline', 'progress'],
    detail: { child: 'task', fk: 'project_id', title: 'Tasks' },
  },

  task: {
    title: 'Tasks', single: 'Task',
    fields: [F.text('title', 'Task', { req: 1 }), F.ref('employee_id', 'Assigned to', 'staff'),
             F.sel('status', 'Status', ['todo', 'doing', 'done'], { badge: 1 }), F.num('est_hours', 'Estimated hours', { step: '0.25' })],
    cols: ['title', 'employee_id', 'status', 'est_hours'],
  },

  timesheet: {
    title: 'Timesheets', single: 'Time entry',
    fields: [F.ref('task_id', 'Task', 'task', { req: 1 }), F.ref('employee_id', 'Employee', 'staff', { req: 1 }),
             F.date('work_date', 'Date'), F.num('hours', 'Hours', { req: 1, step: '0.25' }), F.text('note', 'Note')],
    cols: ['work_date', 'employee_id', 'task_id', 'hours', 'note'],
  },

  // ---------------- HR
  employee: {
    title: 'Employees', single: 'Employee',
    fields: [F.text('name', 'Name', { req: 1 }), F.text('email', 'Email'), F.text('phone', 'Phone'),
             F.text('job_title', 'Job title'), F.money('hourly_rate', 'Hourly rate'), F.date('hire_date', 'Hired on'),
             F.bool('active', 'Active')],
    cols: ['name', 'job_title', 'email', 'hourly_rate', 'active'],
  },

  payslip: {
    title: 'Payslips', single: 'Payslip', readonly: true,
    fields: [F.ref('employee_id', 'Employee', 'staff'), F.date('period_start', 'From'), F.date('period_end', 'To'),
             F.num('hours', 'Hours'), F.money('gross', 'Gross'), F.money('deductions', 'Deductions'), F.money('net', 'Net pay')],
    cols: ['employee_id', 'period_start', 'period_end', 'hours', 'gross', 'deductions', 'net'],
    toolbar: [{
      label: 'Generate payslip', fn: 'fn_generate_payslip', done: 'Payslip generated',
      fields: [F.ref('employee_id', 'Employee', 'staff', { req: 1 }), F.date('period_start', 'From', { req: 1, def: () => monthStartISO() }),
               F.date('period_end', 'To', { req: 1 }), F.num('deduction_pct', 'Deductions %', { step: '0.01', def: 0 })],
    }],
  },

  // ---------------- POS
  cash_register: {
    title: 'Cash registers', single: 'Cash register',
    fields: [F.text('name', 'Name', { req: 1 }), F.ref('warehouse_id', 'Sells from', 'warehouse', { req: 1 }),
             F.money('balance', 'Cash in drawer'), F.sel('status', 'Status', ['open', 'closed'], { badge: 1 })],
    cols: ['name', 'warehouse_id', 'balance', 'status'],
  },

  pos_sale: {
    title: 'POS sales', single: 'POS sale', readonly: true,
    fields: [F.text('number', 'Receipt'), F.ref('register_id', 'Register', 'cash_register'), { k: 'created_at', l: 'When', t: 'datetime' },
             F.text('payment_method', 'Paid by', { badge: 1 }), F.num('discount_pct', 'Discount %'), F.money('total', 'Total')],
    cols: ['number', 'register_id', 'created_at', 'payment_method', 'discount_pct', 'total'],
    detail: { child: 'pos_sale_line', fk: 'sale_id', title: 'Items', readonly: true },
  },

  pos_sale_line: {
    title: 'Items', single: 'Item', readonly: true,
    fields: [F.ref('product_id', 'Product', 'product'), F.num('qty', 'Qty'), F.money('unit_price', 'Price'),
             { k: 'line_total', l: 'Total', t: 'number', ro: 1, m: 1, fmt: r => ({ text: fmtMoney(r.qty * r.unit_price) }) }],
    cols: ['product_id', 'qty', 'unit_price', 'line_total'],
  },
};

// ---------------- Reports (read-only views)
ENTITIES.costing = {
  title: 'Costing & margin', readonly: true,
  fields: [F.text('sku', 'SKU'), F.text('name', 'Product'), F.money('price', 'Sale price'), F.money('unit_cost', 'Unit cost'),
           { k: 'margin', l: 'Margin', t: 'number', m: 1, fmt: r => ({ text: fmtMoney(r.margin), cls: Number(r.margin) < 0 ? 'low' : '' }) },
           { k: 'margin_pct', l: 'Margin %', t: 'number', fmt: r => ({ text: r.margin_pct == null ? '' : r.margin_pct + '%', cls: Number(r.margin_pct) < 20 ? 'low' : '' }) }],
  cols: ['sku', 'name', 'price', 'unit_cost', 'margin', 'margin_pct'],
  note: 'Cost of manufactured products is the material cost from their bill of materials; bought items use their purchase cost.',
};

ENTITIES.ageing = {
  title: 'Receivables ageing', readonly: true,
  fields: [F.ref('partner_id', 'Customer', 'partner'), F.money('not_due', 'Not yet due'), F.money('d1_30', '1–30 days late'),
           F.money('d31_60', '31–60 days late'), F.money('d61_plus', '61+ days late'), F.money('total', 'Total owed')],
  cols: ['partner_id', 'not_due', 'd1_30', 'd31_60', 'd61_plus', 'total'],
  note: 'Unpaid customer invoices grouped by how long past the due date they are.',
};

ENTITIES.reorder = {
  title: 'Reorder suggestions', readonly: true,
  fields: [F.text('sku', 'SKU'), F.text('name', 'Product'), F.ref('vendor_id', 'Preferred vendor', 'partner'),
           { k: 'on_hand', l: 'On hand', t: 'number', fmt: r => ({ text: fmtNum(r.on_hand), cls: 'low' }) },
           F.num('reorder_level', 'Reorder level'), F.num('suggested_qty', 'Suggested order qty')],
  cols: ['sku', 'name', 'vendor_id', 'on_hand', 'reorder_level', 'suggested_qty'],
  note: 'Low-stock products that are not already on an open purchase order. Products without a preferred vendor are skipped when creating orders.',
  toolbar: [{
    label: 'Create purchase orders', fn: 'fn_reorder_create_pos', done: 'Draft purchase orders created',
    fields: [F.ref('warehouse_id', 'Deliver to', 'warehouse', { req: 1 })],
  }],
};

// ---------------- Administration (admin only)
ENTITIES.app_user = {
  title: 'Users', readonly: true,
  fields: [F.text('username', 'Username'), F.text('full_name', 'Name'), F.text('role', 'Role', { badge: 1 }),
           F.bool('active', 'Active'), { k: 'created_at', l: 'Created', t: 'datetime' }],
  cols: ['username', 'full_name', 'role', 'active', 'created_at'],
  note: 'Roles: admin (everything), sales, store, accounts, hr, cashier (POS only), viewer (read-only).',
  toolbar: [
    { label: 'New user', fn: 'fn_create_user', done: 'User created',
      fields: [F.text('username', 'Username (3+ letters, lower case)', { req: 1 }), F.text('full_name', 'Full name'),
               F.sel('role', 'Role', ['admin', 'sales', 'store', 'accounts', 'hr', 'cashier', 'viewer'], { req: 1 }),
               F.pass('password', 'Password (8+ characters)', { req: 1 })] },
    { label: 'Reset password', fn: 'fn_set_password', done: 'Password reset',
      fields: [F.ref('id', 'User', 'app_user', { req: 1 }), F.pass('password', 'New password (8+ characters)', { req: 1 })] },
    { label: 'Activate / deactivate', fn: 'fn_set_user_active', done: 'User updated',
      fields: [F.ref('id', 'User', 'app_user', { req: 1 }), F.bool('active', 'Active')] },
  ],
};

ENTITIES.audit_log = {
  title: 'Audit log', readonly: true,
  fields: [{ k: 'at', l: 'When', t: 'datetime' }, F.text('username', 'User'), F.text('action', 'Action', { badge: 1 }), F.text('target', 'What')],
  cols: ['at', 'username', 'action', 'target'],
  note: 'Every change made through the system, newest first (last 1000).',
};

// Sidebar structure. A string is an entity key; special pages are handled in app.js.
const MENU = [
  { group: 'Overview', items: [['dashboard', 'Dashboard']] },
  { group: 'Sales & CRM', items: [['crm_lead', 'Leads'], ['sales_order', 'Sales orders'], ['partner', 'Customers & vendors']] },
  { group: 'Purchases & Stock', items: [['purchase_order', 'Purchase orders'], ['product', 'Products'], ['stock', 'Stock'],
                                         ['stock_move', 'Stock movements'], ['reorder', 'Reorder suggestions'], ['warehouse', 'Warehouses']] },
  { group: 'Invoicing', items: [['invoice', 'Invoices & payments']] },
  { group: 'Manufacturing', items: [['production_order', 'Production orders'], ['bom', 'Bills of materials'], ['work_center', 'Work centers']] },
  { group: 'Projects', items: [['project', 'Projects'], ['timesheet', 'Timesheets']] },
  { group: 'Human Resources', items: [['employee', 'Employees'], ['payslip', 'Payslips']] },
  { group: 'Reports', items: [['costing', 'Costing & margin'], ['ageing', 'Receivables ageing']] },
  { group: 'Administration', items: [['app_user', 'Users'], ['audit_log', 'Audit log']] },
  { group: 'Point of Sale', items: [['pos', 'POS terminal'], ['pos_sale', 'POS sales'], ['cash_register', 'Cash registers']] },
];
