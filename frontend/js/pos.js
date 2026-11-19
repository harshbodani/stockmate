'use strict';
/* Point of Sale terminal: scan or pick products, apply a discount, take payment. */

async function posPage() {
  const [registers, products] = await Promise.all([api('GET', '/cash_register'), api('GET', '/product')]);
  const open = registers.filter(r => r.status === 'open').reverse();
  if (!open.length) return h('div', { class: 'card' }, 'No open cash register. Open one under Point of Sale → Cash registers.');
  const sellable = products.filter(p => p.active && Number(p.price) > 0);

  let register = open[0];
  let stock = new Map();   // product id -> qty in the register's warehouse
  let cart = [];           // [{ p, qty }]
  let lastReceipt = null;

  const loadStock = async () => {
    const rows = await api('GET', `/stock?warehouse_id=${register.warehouse_id}`);
    stock = new Map(rows.map(r => [r.product_id, Number(r.qty)]));
  };
  await loadStock();

  // --- left: scanner + product tiles
  const scan = h('input', { type: 'text', class: 'scan', placeholder: 'Scan barcode or type SKU, then Enter', 'aria-label': 'Barcode or SKU', autocomplete: 'off' });
  const filter = h('input', { type: 'search', class: 'search', placeholder: 'Search products…', 'aria-label': 'Search products' });
  const tiles = h('div', { class: 'tiles' });

  const drawTiles = () => {
    const q = filter.value.trim().toLowerCase();
    tiles.replaceChildren(...sellable.filter(p => !q || (p.name + p.sku).toLowerCase().includes(q)).map(p => {
      const have = stock.get(p.id) || 0;
      return h('button', { type: 'button', class: 'tile' + (have <= 0 ? ' out' : ''), onclick: () => add(p) },
        h('strong', {}, p.name), h('span', {}, fmtMoney(p.price)), h('small', {}, have > 0 ? `${fmtNum(have)} in stock` : 'Out of stock'));
    }));
  };

  // --- right: cart
  const cartBody = h('tbody');
  const subEl = h('span'), totEl = h('strong');
  const discount = h('input', { id: 'posDisc', type: 'number', min: 0, max: 100, step: '0.5', value: 0, class: 'mini', 'aria-label': 'Discount percent' });
  const method = h('select', { 'aria-label': 'Payment method' }, ['cash', 'card', 'upi'].map(m => h('option', { value: m }, m.toUpperCase())));
  const regSel = h('select', { 'aria-label': 'Cash register' }, open.map(r => h('option', { value: r.id }, r.name)));
  const payBtn = h('button', { type: 'button', class: 'btn primary big' }, 'Charge');
  const receipt = h('p', { class: 'receipt', role: 'status' });

  const totals = () => {
    const sub = cart.reduce((s, l) => s + l.qty * Number(l.p.price), 0);
    const disc = Math.min(100, Math.max(0, Number(discount.value) || 0));
    return { sub, total: Math.round(sub * (1 - disc / 100) * 100) / 100 };
  };

  const drawCart = () => {
    cartBody.replaceChildren(...cart.map((l, i) => h('tr', {},
      h('td', {}, l.p.name, h('br'), h('small', { class: 'muted' }, fmtMoney(l.p.price))),
      h('td', {}, h('input', { type: 'number', min: 1, step: 1, value: l.qty, class: 'mini', 'aria-label': 'Quantity of ' + l.p.name,
        onchange: e => { l.qty = Math.max(1, Math.floor(Number(e.target.value) || 1)); drawCart(); } })),
      h('td', { class: 'num' }, fmtMoney(l.qty * Number(l.p.price))),
      h('td', {}, h('button', { type: 'button', class: 'btn small ghost danger', 'aria-label': 'Remove ' + l.p.name, onclick: () => { cart.splice(i, 1); drawCart(); } }, '✕')))));
    if (!cart.length) cartBody.append(h('tr', {}, h('td', { colspan: 4, class: 'empty' }, 'Cart is empty')));
    const t = totals();
    subEl.textContent = fmtMoney(t.sub);
    totEl.textContent = fmtMoney(t.total);
    payBtn.textContent = cart.length ? `Charge ${fmtMoney(t.total)}` : 'Charge';
    payBtn.disabled = !cart.length;
  };

  function add(p) {
    const line = cart.find(l => l.p.id === p.id);
    const have = stock.get(p.id) || 0;
    if ((line ? line.qty : 0) + 1 > have) { toast(`Only ${fmtNum(have)} of "${p.name}" in stock here`, 'err'); return; }
    if (line) line.qty++; else cart.push({ p, qty: 1 });
    drawCart();
  }

  scan.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    const code = scan.value.trim().toLowerCase();
    if (!code) return;
    const p = sellable.find(x => (x.barcode || '').toLowerCase() === code || x.sku.toLowerCase() === code);
    if (p) add(p); else toast('No product with code ' + scan.value.trim(), 'err');
    scan.value = '';
  });
  filter.addEventListener('input', drawTiles);
  discount.addEventListener('input', drawCart);
  regSel.addEventListener('change', async () => {
    register = open.find(r => r.id === Number(regSel.value));
    cart = []; await loadStock(); drawTiles(); drawCart();
  });

  payBtn.addEventListener('click', async () => {
    payBtn.disabled = true;
    try {
      const res = await api('POST', '/rpc/fn_pos_checkout', {
        register_id: register.id, method: method.value, discount_pct: Number(discount.value) || 0,
        items: cart.map(l => ({ product_id: l.p.id, qty: l.qty })),
      });
      lastReceipt = `Sale ${res.number} complete · ${fmtMoney(res.total)} by ${method.value.toUpperCase()}`;
      receipt.textContent = lastReceipt;
      toast(lastReceipt);
      cart = []; discount.value = 0;
      const regs = await api('GET', '/cash_register'); register = regs.find(r => r.id === register.id) || register;
      await loadStock(); drawTiles(); drawCart();
      scan.focus();
    } catch (e) { toast(e.message, 'err'); payBtn.disabled = false; }
  });

  drawTiles(); drawCart();
  const root = h('div', { class: 'pos' },
    h('section', { class: 'card pos-left' }, scan, filter, tiles),
    h('section', { class: 'card pos-right' },
      h('label', { class: 'inline' }, 'Register ', regSel),
      h('div', { class: 'table-wrap' }, h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Item'), h('th', {}, 'Qty'), h('th', { class: 'num' }, 'Amount'), h('th', {}))), cartBody)),
      h('div', { class: 'sum' }, h('span', {}, 'Subtotal'), subEl),
      h('div', { class: 'sum' }, h('label', { for: 'posDisc' }, 'Discount %'), discount),
      h('div', { class: 'sum total' }, h('span', {}, 'Total'), totEl),
      h('div', { class: 'sum' }, h('span', {}, 'Pay by'), method),
      payBtn, receipt));
  setTimeout(() => scan.focus(), 0);
  return root;
}
