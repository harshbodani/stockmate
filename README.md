# StockMate – Smart Business & Inventory Management System

A web-based system that connects **Sales & CRM, Purchases & Stock, Invoicing & Payments, Manufacturing,
Project Management, Human Resources and Point of Sale** in one database, built for Filtsap Filtration.

| Layer | Technology |
|-------|------------|
| Frontend | JavaScript (no framework), CSS, HTML |
| Backend | Java 17 (JDK `HttpServer` + JDBC) |
| Database | PostgreSQL, business rules written in **PL/pgSQL** |

## Run it

1. Install JDK 17+, Maven and PostgreSQL.
2. Create and fill the database (from the `db/` folder):
   ```bash
   cd db
   ./reset.sh            # drops/creates database "stockmate", loads schema, functions and demo data
   ```
   (or run `schema.sql`, `functions.sql`, `seed.sql` in that order with `psql -d stockmate -f ...`)
3. Start the app from the project root:
   ```bash
   export DB_URL=jdbc:postgresql://localhost:5432/stockmate DB_USER=postgres DB_PASS=yourpassword
   ./run.sh
   ```
4. Open <http://localhost:8080> and sign in (demo accounts below).

> PostgreSQL needs the `pgcrypto` extension (included with the standard installers). `schema.sql` enables it
> automatically; the database owner or a superuser must be allowed to run `CREATE EXTENSION`.

## Sign-in and roles

Demo accounts (created by `seed.sql`; **change the passwords** under Users → Reset password before real use):

| Username | Password | Role | Can do |
|----------|----------|------|--------|
| admin | admin123 | admin | everything, manage users, audit log |
| sales | sales123 | sales | leads, customers, quotations, sales orders |
| store | store123 | store | products, stock and lots, purchasing, manufacturing, quality checks, deliveries |
| accounts | accounts123 | accounts | create invoices, register payments |
| hrdesk | hr123456 | hr | employees, payslips |
| cashier | cashier123 | cashier | POS terminal only |
| viewer | viewer123 | viewer | read-only |

Projects, tasks and timesheets can be edited by sales, store, accounts and hr. Passwords are stored as bcrypt hashes
(never in plain text). Sessions use an HttpOnly, SameSite=Strict cookie; a deactivated user is locked out immediately;
10 wrong passwords from one address in 10 minutes blocks further attempts for a while. Every change is written to the audit log.
The rules live in one file: `backend/src/main/java/com/stockmate/Permissions.java`.

Environment variables: `PORT` (8080), `DB_URL`, `DB_USER` (postgres), `DB_PASS`, `FRONTEND_DIR`; optional `OPENJARVIS_URL`, `OPENJARVIS_API_KEY`, `OPENJARVIS_MODEL` (see *Voice assistant*).

## How it is organised

```
db/schema.sql      tables, constraints, views
db/functions.sql   business logic in PL/pgSQL (stock and lots, deliver/receive, GST invoicing, quotations, QC, production, payroll, POS, PDF data)
db/seed.sql        demo data for a filter business and the demo logins
backend/           Java server: Api (routes), Auth (sessions), Permissions (roles), JdbcDatabase; Pdf + Documents + Json draw the PDFs; serves the frontend
frontend/          single-page app: config.js (screen definitions), app.js (generic screens), dashboard.js, pos.js
```

**Design idea:** every important business rule lives in the database as a function, so it cannot be bypassed and is
applied inside one transaction. The Java layer is thin: it whitelists table and function names and passes JSON through.
The frontend is driven by `config.js`, a description of each screen, so adding a field is a one-line change.

## Modules and what they do

| Module | Screens | Main logic |
|--------|---------|-----------|
| Sales & CRM | Leads, Quotations, Sales orders, Customers & vendors | Lead stages and activity history; **Convert lead → customer**; quotation → sent → accepted → **convert to order** → confirm → deliver (stock goes down) |
| Purchases & Stock | Purchase orders, Products, Stock, Stock movements, Warehouses | Receive goods (stock goes up, cost updates); multi-warehouse quantities; every change logged in `stock_move`; low-stock alerts |
| Invoicing & Payments | Invoices & payments | **GST invoice** from an order (HSN, CGST+SGST or IGST, round-off, amount in words); partial payments; status open → partial → paid; overdue flag; overpayment blocked |
| Quality | Quality checks | Inspection with test readings against min/max; any reading out of range fails it and blocks the lot |
| Manufacturing | Production orders, Bills of materials, Work centers | Completing an order consumes BOM components and adds finished goods; work orders per operation |
| Project Management | Projects, Tasks, Timesheets | Task status, hours logged per project, progress |
| Human Resources | Employees, Payslips | Payslip = timesheet hours × hourly rate − deductions % |
| Point of Sale | POS terminal, POS sales, Cash registers | Barcode scan, discount, cash/card/UPI, stock and cash drawer updated together |

### Filtration-specific features

- **Product specifications:** micron rating, size, material, flow rate and "fits / compatible with", searchable in the product list.
- **Costing & margin:** unit cost of manufactured products from their bill of materials, margin and margin % per product.
- **Receivables ageing:** what each customer owes, in not-due / 1–30 / 31–60 / 61+ days late buckets.
- **Reorder suggestions:** low-stock products not already on an open order; one click creates a draft purchase order per preferred vendor.
- **Warehouse transfers:** move stock between the Main Warehouse and Production Store, logged on both sides.
- **CSV export** on every list.

### Batch / lot tracking, quotations, GST, quality control, PDF

- **Lots:** mark a product *Track by batch / lot*. Goods received get a lot (supplier lot number and expiry can be typed on the purchase line),
  finished goods get the production order number as lot. Stock leaves **earliest-expiry first, then oldest first**; rejected and expired lots are never issued.
  *Batches & lots* shows on-hand, expiry status (ok / expiring within 30 days / expired / rejected) and, per lot, a **traceability history**
  (where it came from, which lots it was made from or used to make, and its movements). Transfers keep the lot.
- **Quotations:** draft → sent → accepted/declined → converted. Converting creates a draft sales order with the same lines and marks the CRM lead won.
  Expired quotations must be revised before they can be converted. Prices are before GST; the screen shows GST and the total.
- **GST invoices:** the company state code (Company settings) is compared with the customer's state code. Same state: CGST + SGST (half each);
  different state: IGST. Each product has an HSN code and GST rate; each partner a GSTIN and state code. Totals are rounded to the rupee with the round-off shown.
- **Quality control:** record an incoming, in-process or final inspection with readings. Completing it passes the lot, or (if a reading is out of range)
  fails it with a decision (accept / rework / scrap / return to vendor) and blocks the lot.
- **PDF export:** invoices (with HSN table and amount in words), quotations, QC reports and payslips: use the **PDF** button on the list or detail screen
  (`GET /api/pdf/{invoice|quotation|qc|payslip}/{id}`). The PDF writer is plain Java with the standard Helvetica fonts; the rupee sign is printed as "Rs.".

> **Check before real use:** the GSTIN, bank details, HSN codes and 18 % GST rate in the demo data are **samples**, not real values.
> Confirm HSN codes, rates and invoice format with your accountant. This project does not file GST returns or generate e-invoices / e-way bills.

### Voice assistant (wake word + OpenJarvis)

Click **🎤 Assistant** in the top bar. Ask by typing, press 🎤 to speak one question, or switch on
*Listen for the wake phrase "Hey StockMate"* (off by default) and just say, for example, *"Hey StockMate, how much stock of cartridges?"*
or *"Hey StockMate"* … *"any overdue invoices?"*. Answers are shown and read aloud.

```
browser (wake phrase + speech in/out)  →  POST /api/assistant  →  built-in read-only answers (stock, low stock, money owed,
                                                                  overdue, expiring lots, today's sales, open orders, QC)
                                                              →  anything else → OpenJarvis (optional)
```

- **Where it lives:** the microphone and wake phrase are in the browser (`frontend/js/voice.js`) because that is where the microphone is.
  The server (`Assistant.java`) answers using the signed-in user's role, so a cashier cannot hear finance figures. It only reads; it never changes data.
- **OpenJarvis (optional):** run an [OpenJarvis](https://github.com/open-jarvis/OpenJarvis) server (`jarvis serve`, an OpenAI-compatible API) and start StockMate with
  `OPENJARVIS_URL=http://localhost:<port>` (plus `OPENJARVIS_API_KEY` / `OPENJARVIS_MODEL` if your setup needs them). Questions the built-in answers do not
  cover are sent to `/v1/chat/completions` together with the dashboard figures that user may see. OpenJarvis gets no database access. Without it, the built-in answers still work.
- **Wake phrase and privacy:** recognition uses the browser's speech service (Chrome or Edge), which sends microphone audio to the browser vendor while the switch is on.
  Nothing is sent to StockMate until the wake phrase is heard. For fully offline wake-word detection a dedicated engine (e.g. openWakeWord or Porcupine) would replace this part.
- **Status:** tested with simulated speech events and a stand-in OpenJarvis server; not yet tried against a real OpenJarvis install or a real microphone.

Dashboard: stock value, low-stock count, money to collect/pay, today's POS sales, open orders, 7-day sales chart, reorder list, recent movements.

## Integrity rules enforced by the database

- Stock can never go negative; the error names the product and quantities.
- A failed action (e.g. delivering more than is in stock) changes nothing – the whole action is rolled back.
- Order status only changes through the action buttons, never by editing the record directly.
- Order lines can only be edited while the order is a draft.
- Payments cannot exceed the invoice balance and cannot be edited or deleted.

## API (used by the frontend)

```
GET    /api/{entity}?column=value     list, optional filter        GET /api/dashboard
GET    /api/{entity}/{id}             one record                   POST /api/rpc/{function}   run an action
POST   /api/{entity}                  create                       PUT/DELETE /api/{entity}/{id}
```

## Known limits / future work

- Not done yet: customer replacement reminders, credit notes, GST returns / e-invoice / e-way bill, serial numbers per unit, QC sampling plans, PDFs with non-Latin text.
- Single currency (INR) and a single company.
- Sessions are kept in server memory, so everyone is signed out when the server restarts.
- Serve it over HTTPS (for example behind a reverse proxy) before exposing it beyond a local network.

## Credits

The module list follows the common ERP structure used by open-source systems such as Odoo and MyCompany (lsFusion).
No code from those projects is used; the schema, logic and screens in this repository were written for StockMate.

next

