'use strict';
/* Dashboard: key numbers, a 7-day sales chart, low-stock list and recent stock movements. */

const SVG_NS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs, ...kids) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  for (const kid of kids) if (kid != null) el.append(kid.nodeType ? kid : document.createTextNode(kid));
  return el;
}

function salesChart(days) {
  const W = 640, H = 220, pad = { l: 56, r: 12, t: 12, b: 28 };
  const max = Math.max(1, ...days.flatMap(d => [Number(d.pos), Number(d.invoiced)]));
  const step = Math.pow(10, Math.floor(Math.log10(max)));
  const top = Math.ceil(max / step) * step;
  const plotW = W - pad.l - pad.r, plotH = H - pad.t - pad.b;
  const y = v => pad.t + plotH - (v / top) * plotH;
  const groupW = plotW / days.length, barW = Math.min(22, groupW / 3);

  const s = svg('svg', { viewBox: `0 0 ${W} ${H}`, class: 'chart', role: 'img',
    'aria-label': 'Sales over the last 7 days: POS sales and invoiced amounts per day' });
  for (let i = 0; i <= 4; i++) {
    const v = (top / 4) * i;
    s.append(svg('line', { x1: pad.l, x2: W - pad.r, y1: y(v), y2: y(v), class: 'grid' }),
      svg('text', { x: pad.l - 8, y: y(v) + 4, class: 'axis', 'text-anchor': 'end' }, v >= 1000 ? (v / 1000) + 'k' : v));
  }
  days.forEach((d, i) => {
    const cx = pad.l + groupW * i + groupW / 2;
    [['pos', -barW - 1, 'bar-a', 'POS'], ['invoiced', 1, 'bar-b', 'Invoiced']].forEach(([k, dx, cls, name]) => {
      const v = Number(d[k]);
      s.append(svg('rect', { x: cx + dx, y: y(v), width: barW, height: Math.max(0, y(0) - y(v)), class: cls, rx: 2 },
        svg('title', {}, `${d.day} · ${name}: ${fmtMoney(v)}`)));
    });
    s.append(svg('text', { x: cx, y: H - 8, class: 'axis', 'text-anchor': 'middle' }, d.day));
  });
  return s;
}

async function dashboardPage() {
  const d = await api('GET', '/dashboard');
  const kpis = [
    ['Stock value', fmtMoney(d.stock_value), `${d.products} active products`, 'stock', ''],
    ['Low-stock items', d.low_stock, 'at or below reorder level', 'product', d.low_stock > 0 ? 'warn' : ''],
    ['To collect', fmtMoney(d.receivable), `${d.overdue_invoices} overdue invoice${d.overdue_invoices === 1 ? '' : 's'}`, 'invoice', d.overdue_invoices > 0 ? 'warn' : ''],
    ['To pay', fmtMoney(d.payable), 'vendor bills', 'invoice', ''],
    ['POS sales today', fmtMoney(d.pos_today), '', 'pos_sale', ''],
    ['Open sales orders', d.open_sales_orders, 'draft or confirmed', 'sales_order', ''],
    ['Open purchase orders', d.open_purchase_orders, 'draft or confirmed', 'purchase_order', ''],
    ['Production', d.running_production, 'planned or in progress', 'production_order', ''],
    ['Lots expiring', d.expiring_lots, 'within 30 days or expired, still in stock', 'lot', d.expiring_lots > 0 ? 'warn' : ''],
    ['Failed quality checks', d.qc_failed_30d, 'last 30 days', 'qc_inspection', d.qc_failed_30d > 0 ? 'warn' : ''],
    ['Open leads', d.open_leads, '', 'crm_lead', ''],
    ['Active projects', d.active_projects, `${d.employees} employees`, 'project', ''],
  ];

  const lowTable = d.low_stock_items.length
    ? h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Product'), h('th', { class: 'num' }, 'On hand'), h('th', { class: 'num' }, 'Reorder at'))),
      h('tbody', {}, d.low_stock_items.map(p => h('tr', {}, h('td', {}, `${p.sku} · ${p.name}`),
        h('td', { class: 'num low' }, fmtNum(p.on_hand)), h('td', { class: 'num' }, fmtNum(p.reorder_level)))))))
    : h('p', { class: 'muted' }, 'Everything is above its reorder level.');

  const movesTable = h('div', { class: 'table-wrap' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', {}, 'When'), h('th', {}, 'Product'), h('th', {}, 'Reason'), h('th', { class: 'num' }, 'Qty'))),
    h('tbody', {}, d.recent_moves.map(m => h('tr', {}, h('td', {}, fmtDateTime(m.created_at)), h('td', {}, m.product),
      h('td', {}, h('span', { class: 'badge b-' + m.reason }, pretty(m.reason))),
      h('td', { class: 'num ' + (m.qty < 0 ? 'loss' : 'gain') }, (m.qty > 0 ? '+' : '') + fmtNum(m.qty)))))));

  return h('div', {},
    h('div', { class: 'kpis' }, kpis.map(([label, value, sub, href, tone]) =>
      h('a', { class: 'kpi ' + tone, href: '#/' + href }, h('span', { class: 'kpi-l' }, label), h('span', { class: 'kpi-v' }, String(value)), h('span', { class: 'kpi-s' }, sub)))),
    h('div', { class: 'grid2' },
      h('section', { class: 'card' }, h('h3', {}, 'Last 7 days'),
        h('div', { class: 'legend' }, h('span', { class: 'sw a' }), 'POS sales', h('span', { class: 'sw b' }), 'Invoiced'),
        salesChart(d.sales_7d)),
      h('section', { class: 'card' }, h('h3', {}, 'Needs reordering'), lowTable)),
    h('section', { class: 'card' }, h('h3', {}, 'Recent stock movements'), movesTable));
}
