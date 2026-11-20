'use strict';
/* StockMate front end: shared helpers, generic list / detail / form screens and the router. */

// ------------------------------------------------------------------ tiny DOM helper
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'checked') el.checked = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(kid));
  }
  return el;
}
const $ = (sel, el = document) => el.querySelector(sel);

// ------------------------------------------------------------------ formatting
const nf = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 3 });
const mf = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' });
function fmtNum(v) { return v == null || v === '' ? '' : nf.format(Number(v)); }
function fmtMoney(v) { return v == null || v === '' ? '' : mf.format(Number(v)); }
function fmtDate(v) {
  if (!v) return '';
  return new Date(v + 'T00:00:00').toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}
function fmtDateTime(v) {
  if (!v) return '';
  return new Date(v).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}
function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function monthStartISO() { return todayISO().slice(0, 8) + '01'; }
const pretty = s => String(s).replace(/_/g, ' ');

// ------------------------------------------------------------------ who is signed in
let ME = null; // { username, full_name, role, can_read[], can_write[], can_rpc[] }
const canRead = key => !!ME && ME.can_read.includes(key);
const canWrite = key => !!ME && ME.can_write.includes(key);
const canRpc = fn => !!ME && ME.can_rpc.includes(fn);

// ------------------------------------------------------------------ server calls
async function api(method, path, body) {
  const res = await fetch('/api' + path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = JSON.parse(text); } catch (e) { /* not JSON */ }
  if (res.status === 401 && path !== '/login' && path !== '/me') { ME = null; showLogin('Your session ended. Please sign in again.'); }
  if (!res.ok) throw new Error((data && data.error) || res.statusText || 'Request failed');
  return data;
}

function toast(msg, kind = 'ok') {
  const t = h('div', { class: 'toast ' + kind, role: 'status' }, msg);
  const box = $('#toasts');
  box.append(t);
  while (box.children.length > 3) box.firstChild.remove();
  setTimeout(() => t.remove(), kind === 'err' ? 6000 : 3000);
}

// ------------------------------------------------------------------ lookup data for dropdowns & labels
let refData = {}; // entity name -> Map(id -> row)

async function ensureRefs(names) {
  await Promise.all([...new Set(names)].filter(n => !refData[n]).map(async n => {
    const rows = await api('GET', '/' + n);
    refData[n] = new Map(rows.map(r => [r.id, r]));
  }));
}
function refsFor(...entities) {
  const out = [];
  for (const E of entities) if (E) for (const f of E.fields) if (f.t === 'ref') out.push(f.ref);
  return out;
}
function refText(name, id) {
  const row = refData[name] && refData[name].get(Number(id));
  return row ? LABEL[name](row) : '#' + id;
}
const invalidateRefs = () => { refData = {}; };

// ------------------------------------------------------------------ cells
function cell(f, row) {
  if (f.fmt) {
    const o = f.fmt(row);
    return o.cls ? h('span', { class: o.cls }, o.text) : o.text;
  }
  const v = row[f.k];
  if (v == null || v === '') return '';
  if (f.t === 'ref') return refText(f.ref, v);
  if (f.t === 'bool') return v ? 'Yes' : 'No';
  if (f.badge) return h('span', { class: 'badge b-' + String(v).replace(/\W/g, '_') }, pretty(v));
  if (f.t === 'date') return fmtDate(v);
  if (f.t === 'datetime') return fmtDateTime(v);
  if (f.m) return fmtMoney(v);
  if (f.t === 'number') return fmtNum(v);
  return String(v);
}
const fieldOf = (E, k) => E.fields.find(f => f.k === k);
const isNumeric = f => f.t === 'number';

function table(E, rows, { onRow, rowButtons } = {}) {
  const cols = E.cols.map(k => fieldOf(E, k));
  const thead = h('thead', {}, h('tr', {}, cols.map(f => h('th', { class: isNumeric(f) ? 'num' : '' }, f.l)), rowButtons ? h('th', { class: 'act-col' }) : null));
  const tbody = h('tbody');
  for (const r of rows) {
    const tr = h('tr', { class: [onRow ? 'click' : '', E.rowClass ? E.rowClass(r) : ''].join(' ').trim() },
      cols.map((f, i) => h('td', { class: isNumeric(f) ? 'num' : '' }, i === 0 && onRow ? h('a', { href: '#', onclick: e => { e.preventDefault(); onRow(r); } }, cell(f, r)) : cell(f, r))),
      rowButtons ? h('td', { class: 'act-col' }, rowButtons(r)) : null);
    if (onRow) tr.addEventListener('click', e => { if (!e.target.closest('button, a')) onRow(r); });
    tbody.append(tr);
  }
  if (!rows.length) tbody.append(h('tr', {}, h('td', { colspan: cols.length + (rowButtons ? 1 : 0), class: 'empty' }, 'Nothing here yet.')));
  return h('div', { class: 'table-wrap' }, h('table', {}, thead, tbody));
}

// ------------------------------------------------------------------ forms (native <dialog>)
async function openForm({ title, fields, values = {}, submitLabel = 'Save', onSubmit }) {
  await ensureRefs(refsFor({ fields })); // dropdown data may have just been cleared by a save
  const dlg = h('dialog', { class: 'modal' });
  const err = h('p', { class: 'form-err', role: 'alert' });
  const inputs = {};

  const rowsEl = fields.filter(f => !f.ro).map(f => {
    let input;
    const id = 'f_' + f.k;
    let v = values[f.k];
    if (v === undefined) v = typeof f.def === 'function' ? f.def() : f.def;
    if (v === undefined && f.t === 'date' && !f.nodef) v = todayISO();

    if (f.t === 'textarea') input = h('textarea', { id, rows: 3 });
    else if (f.t === 'select' || f.t === 'ref') {
      input = h('select', { id });
      if (f.t === 'ref' || !f.req) input.append(h('option', { value: '' }, f.t === 'ref' ? '— choose —' : ''));
      const opts = f.t === 'select' ? f.opts.map(o => [o, pretty(o)])
        : [...refData[f.ref].values()].map(r => [r.id, LABEL[f.ref](r)]);
      for (const [val, text] of opts) input.append(h('option', { value: val }, text));
    } else if (f.t === 'bool') input = h('input', { id, type: 'checkbox' });
    else input = h('input', { id, type: f.t === 'number' ? 'number' : f.t === 'date' ? 'date' : f.t === 'password' ? 'password' : 'text', autocomplete: f.t === 'password' ? 'new-password' : null, step: f.t === 'number' ? (f.step || 'any') : null });

    if (f.req) input.required = true;
    if (f.t === 'bool') input.checked = v === undefined ? true : !!v;
    else if (v != null) input.value = v;
    else if (f.t === 'select' && f.req) input.value = f.opts[0];
    inputs[f.k] = input;

    return f.t === 'bool'
      ? h('label', { class: 'check', for: id }, input, f.l)
      : h('div', { class: 'field' }, h('label', { for: id }, f.l, f.req ? h('span', { class: 'req', 'aria-hidden': 'true' }, ' *') : null), input);
  });

  // e.g. choosing a product fills in its price
  for (const f of fields) {
    if (!f.fillFrom) continue;
    const src = inputs[f.fillFrom.src];
    if (src) src.addEventListener('change', () => {
      const row = refData[fields.find(x => x.k === f.fillFrom.src).ref].get(Number(src.value));
      if (row) inputs[f.k].value = row[f.fillFrom.prop];
    });
  }

  const form = h('form', { novalidate: false },
    h('h2', {}, title), rowsEl, err,
    h('div', { class: 'modal-actions' },
      h('button', { type: 'button', class: 'btn ghost', onclick: () => dlg.close() }, 'Cancel'),
      h('button', { type: 'submit', class: 'btn primary' }, submitLabel)));

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const data = {};
    for (const f of fields.filter(x => !x.ro)) {
      const el = inputs[f.k];
      if (f.t === 'bool') data[f.k] = el.checked;
      else if (el.value === '') data[f.k] = null;
      else data[f.k] = (f.t === 'number' || f.t === 'ref') ? Number(el.value) : el.value;
    }
    const btn = $('button[type=submit]', form);
    btn.disabled = true; err.textContent = '';
    try { await onSubmit(data); dlg.close(); }
    catch (ex) { err.textContent = ex.message; btn.disabled = false; }
  });

  dlg.append(form);
  dlg.addEventListener('close', () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
  const first = $('input:not([type=checkbox]), select, textarea', form);
  if (first) first.focus();
}

// ------------------------------------------------------------------ create / edit / delete
function newRecord(key, extra = {}) {
  const E = ENTITIES[key];
  openForm({
    title: 'New ' + E.single.toLowerCase(), fields: E.fields,
    onSubmit: async d => { await api('POST', '/' + key, { ...d, ...extra }); invalidateRefs(); toast(E.single + ' saved'); render(); },
  });
}
function editRecord(key, row) {
  const E = ENTITIES[key];
  openForm({
    title: 'Edit ' + E.single.toLowerCase(), fields: E.fields, values: row,
    onSubmit: async d => { await api('PUT', `/${key}/${row.id}`, d); invalidateRefs(); toast('Changes saved'); render(); },
  });
}
async function deleteRecord(key, row, after) {
  const E = ENTITIES[key];
  if (!confirm(`Delete this ${E.single.toLowerCase()}?`)) return;
  try { await api('DELETE', `/${key}/${row.id}`); invalidateRefs(); toast('Deleted'); (after || render)(); }
  catch (e) { toast(e.message, 'err'); }
}
async function runAction(a, row) {
  if (a.confirm && !confirm(a.confirm)) return;
  const send = async extra => {
    const res = await api('POST', '/rpc/' + a.fn, { ...(a.body ? a.body(row) : { id: row.id }), ...extra });
    invalidateRefs();
    toast(a.done || 'Done');
    const target = res && (res[a.linkKey || 'invoice_id']);
    if (a.link && target) location.hash = `#/${a.link}/${target}`; else render();
  };
  if (a.form) { openForm({ title: a.label, fields: a.form, submitLabel: a.label, onSubmit: d => send(d) }); return; }
  try { await send({}); } catch (e) { toast(e.message, 'err'); }
}

const pdfLink = (type, id, cls = 'btn small ghost') =>
  h('a', { class: cls, href: `/api/pdf/${type}/${id}`, target: '_blank', rel: 'noopener' }, 'PDF');
function runToolbar(t) {
  openForm({
    title: t.label, fields: t.fields, submitLabel: t.label,
    onSubmit: async d => { await api('POST', '/rpc/' + t.fn, d); invalidateRefs(); toast(t.done || 'Done'); render(); },
  });
}

function exportCsv(E, rows, name) {
  const cols = E.cols.map(k => fieldOf(E, k));
  const raw = (f, r) => {
    if (f.fmt) return f.fmt(r).text;
    const v = r[f.k];
    if (v == null) return '';
    return f.t === 'ref' ? refText(f.ref, v) : String(v);
  };
  const q = s => '"' + String(s).replace(/"/g, '""') + '"';
  const csv = [cols.map(f => q(f.l)).join(','), ...rows.map(r => cols.map(f => q(raw(f, r))).join(','))].join('\r\n');
  const url = URL.createObjectURL(new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8' }));
  const a = h('a', { href: url, download: name + '.csv' });
  document.body.append(a); a.click(); a.remove(); URL.revokeObjectURL(url);
}

const iconBtn = (label, onclick, cls = '') => h('button', { type: 'button', class: 'btn small ghost ' + cls, onclick }, label);

// ------------------------------------------------------------------ list screen
async function listPage(key) {
  const E = ENTITIES[key];
  await ensureRefs(refsFor(E, E.toolbar && { fields: E.toolbar.flatMap(t => t.fields) }));
  const rows = await api('GET', '/' + key);
  const canMake = !E.readonly && canWrite(key);
  const canEdit = r => canMake && (!E.editable || E.editable(r));
  const hasId = rows.length === 0 || rows[0].id !== undefined;

  const search = h('input', { type: 'search', class: 'search', placeholder: 'Search…', 'aria-label': 'Search this list' });
  const bar = h('div', { class: 'bar' }, search, h('span', { class: 'grow' }),
    h('button', { class: 'btn', onclick: () => exportCsv(E, rows, key) }, 'Export CSV'),
    (E.toolbar || []).filter(t => canRpc(t.fn)).map(t => h('button', { class: 'btn', onclick: () => runToolbar(t) }, t.label)),
    canMake ? h('button', { class: 'btn primary', onclick: () => newRecord(key) }, '+ New ' + E.single.toLowerCase()) : null);

  const open = r => { location.hash = `#/${key}/${r.id}`; };
  const tbl = table(E, rows, {
    onRow: !hasId ? null : E.detail ? open : (canMake ? r => { if (canEdit(r)) editRecord(key, r); } : null),
    rowButtons: (canMake || E.pdf) && hasId ? r => [
      E.pdf ? pdfLink(E.pdf, r.id) : null,
      canEdit(r) ? iconBtn('Edit', () => editRecord(key, r)) : null,
      canEdit(r) ? iconBtn('Delete', () => deleteRecord(key, r), 'danger') : null,
    ] : null,
  });
  search.addEventListener('input', () => {
    const q = search.value.trim().toLowerCase();
    for (const tr of $('tbody', tbl).rows) tr.hidden = q && !tr.textContent.toLowerCase().includes(q);
  });
  return h('div', {}, E.note ? h('p', { class: 'muted' }, E.note) : null, bar, tbl, h('p', { class: 'muted count' }, `${rows.length} record${rows.length === 1 ? '' : 's'}`));
}

// ------------------------------------------------------------------ detail screen (header + child lines)
async function detailPage(key, id) {
  const E = ENTITIES[key];
  const Ds = Array.isArray(E.detail) ? E.detail : [E.detail];
  await ensureRefs(refsFor(E, ...Ds.map(D => ENTITIES[D.child])));
  const [row, ...kidSets] = await Promise.all([api('GET', `/${key}/${id}`), ...Ds.map(D => api('GET', `/${D.child}?${D.fk}=${id}`))]);
  const mayEdit = !E.readonly && canWrite(key) && (!E.editable || E.editable(row));
  const title = E.fields.find(f => f.k === 'number') ? row.number : (LABEL[key] ? LABEL[key](row) : E.single + ' #' + row.id);

  const actions = (E.actions || []).filter(a => canRpc(a.fn) && (!a.show || a.show(row)))
    .map(a => h('button', { class: 'btn ' + (a.danger ? 'danger' : 'primary'), onclick: () => runAction(a, row) }, a.label));

  const head = h('div', { class: 'detail-head' },
    h('div', {}, h('a', { href: `#/${key}`, class: 'back' }, '← ' + E.title), h('h2', {}, title)),
    h('div', { class: 'row-gap' }, E.pdf ? pdfLink(E.pdf, row.id, 'btn') : null, mayEdit ? iconBtn('Edit', () => editRecord(key, row)) : null, actions));

  const props = h('dl', { class: 'props' },
    E.fields.filter(f => !(f.t === 'ref' && row[f.k] == null)).map(f => [h('dt', {}, f.l), h('dd', {}, cell(f, row) || '—')]));

  const sections = Ds.map((D, i) => {
    const C = ENTITIES[D.child];
    const kidsEditable = !D.readonly && canWrite(D.child) && (!D.editable || D.editable(row));
    const childTable = table(C, kidSets[i], {
      rowButtons: kidsEditable ? r => [
        D.noEdit ? null : iconBtn('Edit', () => openForm({
          title: 'Edit ' + C.single.toLowerCase(), fields: C.fields, values: r,
          onSubmit: async d => { await api('PUT', `/${D.child}/${r.id}`, d); toast('Saved'); render(); },
        })),
        D.noEdit ? null : iconBtn('Delete', () => deleteRecord(D.child, r), 'danger'),
      ] : null,
    });
    // payments default to the outstanding balance; every other child just opens the generic form
    const addHandler = D.child === 'payment'
      ? () => openForm({
        title: 'Register payment', fields: C.fields, values: { amount: row.balance }, submitLabel: 'Register payment',
        onSubmit: async d => { await api('POST', '/payment', { ...d, invoice_id: Number(id) }); toast('Payment registered'); render(); },
      })
      : () => newRecord(D.child, { [D.fk]: Number(id) });
    const addBtn = kidsEditable ? h('button', { class: 'btn primary', onclick: addHandler }, '+ Add ' + C.single.toLowerCase()) : null;
    return [h('div', { class: 'bar' }, h('h3', {}, D.title || C.title), h('span', { class: 'grow' }), addBtn), childTable];
  });

  // order-like documents show the GST build-up under the lines
  const total = ['sales_order', 'purchase_order', 'quotation'].includes(key)
    ? h('div', { class: 'total' },
      h('div', {}, 'Before GST ', h('strong', {}, fmtMoney(row.total))),
      h('div', {}, 'GST ', h('strong', {}, fmtMoney(row.tax))),
      h('div', {}, 'Total ', h('strong', {}, fmtMoney(row.grand_total)))) : null;

  return h('div', {}, head, h('div', { class: 'card' }, props), sections, total);
}

// ------------------------------------------------------------------ company settings (a single record)
async function companyPage() {
  const E = ENTITIES.company;
  const rows = await api('GET', '/company');
  const row = rows[0];
  const props = h('dl', { class: 'props' }, E.fields.map(f => [h('dt', {}, f.l), h('dd', {}, cell(f, row) || '—')]));
  const edit = canWrite('company') ? h('button', { class: 'btn primary', onclick: () => openForm({
    title: 'Company settings', fields: E.fields, values: row,
    onSubmit: async d => { await api('PUT', '/company/1', d); toast('Saved'); render(); },
  }) }, 'Edit') : null;
  return h('div', {}, h('p', { class: 'muted' }, 'These details are printed on invoices and quotations. The state code decides whether a sale is charged CGST + SGST (same state) or IGST (other state).'),
    h('div', { class: 'bar' }, h('span', { class: 'grow' }), edit), h('div', { class: 'card' }, props));
}

// ------------------------------------------------------------------ router
let renderToken = 0;
async function render() {
  const my = ++renderToken;
  const [key, id] = (location.hash.slice(2) || 'dashboard').split('/');
  const view = $('#view');
  document.querySelectorAll('#nav a').forEach(a => a.classList.toggle('active', a.dataset.key === key || (a.dataset.key === 'invoice' && key === 'payment')));
  $('#sidebar').classList.remove('open');

  const titles = { dashboard: 'Dashboard', pos: 'POS terminal' };
  $('#pageTitle').textContent = titles[key] || (ENTITIES[key] && ENTITIES[key].title) || 'Not found';
  document.title = $('#pageTitle').textContent + ' · StockMate';

  try {
    let node;
    if (key === 'dashboard') node = ME.can_dashboard ? await dashboardPage() : h('div', { class: 'card' }, 'Your role does not have access to the dashboard.');
    else if (key === 'pos') node = canRpc('fn_pos_checkout') ? await posPage() : h('div', { class: 'card' }, 'Your role does not have access to the POS terminal.');
    else if (key === 'company' && canRead(key)) node = await companyPage();
    else if (ENTITIES[key] && !canRead(key)) node = h('div', { class: 'card' }, 'Your role does not have access to this page.');
    else if (ENTITIES[key] && id && ENTITIES[key].detail) node = await detailPage(key, id);
    else if (ENTITIES[key]) node = await listPage(key);
    else node = h('p', { class: 'muted' }, 'That page does not exist.');
    if (my === renderToken) { view.replaceChildren(node); view.dataset.page = key + (id ? '/' + id : ''); view.focus({ preventScroll: true }); }
  } catch (e) {
    if (my === renderToken) view.replaceChildren(h('div', { class: 'card err-card' }, h('strong', {}, 'Something went wrong. '), e.message));
  }
}

function buildNav() {
  const nav = $('#nav');
  nav.replaceChildren();
  for (const g of MENU) {
    const items = g.items.filter(([k]) => (k === 'dashboard' ? ME.can_dashboard : k === 'pos' ? canRpc('fn_pos_checkout') : canRead(k)));
    if (!items.length) continue;
    nav.append(h('div', { class: 'nav-group' }, g.group),
      ...items.map(([k, label]) => h('a', { href: '#/' + k, 'data-key': k }, label)));
  }
}

function showLogin(message) {
  document.body.classList.add('locked');
  $('#loginErr').textContent = message || '';
  $('#loginUser').focus();
}

async function startApp() {
  ME = await api('GET', '/me');
  invalidateRefs();
  document.body.classList.remove('locked');
  $('#userName').textContent = `${ME.full_name || ME.username} · ${ME.role}`;
  buildNav();
  initVoice();
  if (!ME.can_dashboard && (location.hash === '' || location.hash === '#/dashboard')) location.hash = '#/pos';
  render();
}

async function boot() {
  $('#menuBtn').addEventListener('click', () => $('#sidebar').classList.toggle('open'));
  window.addEventListener('hashchange', () => { if (ME) render(); });

  $('#loginForm').addEventListener('submit', async e => {
    e.preventDefault();
    $('#loginErr').textContent = '';
    try {
      await api('POST', '/login', { username: $('#loginUser').value, password: $('#loginPass').value });
      $('#loginPass').value = '';
      await startApp();
    } catch (err) { $('#loginErr').textContent = err.message; }
  });
  $('#logoutBtn').addEventListener('click', async () => {
    try { await api('POST', '/logout', {}); } catch (e) { /* already signed out */ }
    stopVoice(); ME = null; invalidateRefs(); $('#view').replaceChildren(); location.hash = '#/dashboard'; showLogin();
  });
  $('#pwBtn').addEventListener('click', () => openForm({
    title: 'Change password', submitLabel: 'Change password',
    fields: [F.pass('old_password', 'Current password', { req: 1 }), F.pass('new_password', 'New password (8+ characters)', { req: 1 })],
    onSubmit: async d => { await api('POST', '/password', d); toast('Password changed'); },
  }));

  try { await startApp(); } catch (e) { showLogin(); }
}
