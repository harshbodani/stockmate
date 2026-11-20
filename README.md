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
| sales | sales123 | sales | leads, customers, sales orders |
| store | store123 | store | products, stock, purchasing, manufacturing, deliveries |
| accounts | accounts123 | accounts | create invoices, register payments |
| hrdesk | hr123456 | hr | employees, payslips |
| cashier | cashier123 | cashier | POS terminal only |
| viewer | viewer123 | viewer | read-only |

Projects, tasks and timesheets can be edited by sales, store, accounts and hr. Passwords are stored as bcrypt hashes
(never in plain text). Sessions use an HttpOnly, SameSite=Strict cookie; a deactivated user is locked out immediately;
10 wrong passwords from one address in 10 minutes blocks further attempts for a while. Every change is written to the audit log.
The rules live in one file: `backend/src/main/java/com/stockmate/Permissions.java`.

Environment variables: `PORT` (8080), `DB_URL`, `DB_USER` (postgres), `DB_PASS`, `FRONTEND_DIR`.

## How it is organised

```
db/schema.sql      tables, constraints, views
db/functions.sql   business logic in PL/pgSQL (stock moves, deliver/receive, invoicing, production, payroll, POS)
db/seed.sql        demo data for a filter business and the demo logins
backend/           Java server: Api (routes), Auth (sessions), Permissions (roles), JdbcDatabase; serves the frontend
frontend/          single-page app: config.js (screen definitions), app.js (generic screens), dashboard.js, pos.js
```

**Design idea:** every important business rule lives in the database as a function, so it cannot be bypassed and is
applied inside one transaction. The Java layer is thin: it whitelists table and function names and passes JSON through.
The frontend is driven by `config.js`, a description of each screen, so adding a field is a one-line change.

## Modules and what they do

| Module | Screens | Main logic |
|--------|---------|-----------|
| Sales & CRM | Leads, Sales orders, Customers & vendors | Lead stages and activity history; **Convert lead → customer**; order → confirm → deliver (stock goes down) |
| Purchases & Stock | Purchase orders, Products, Stock, Stock movements, Warehouses | Receive goods (stock goes up, cost updates); multi-warehouse quantities; every change logged in `stock_move`; low-stock alerts |
| Invoicing & Payments | Invoices & payments | Invoice from an order; partial payments; status open → partial → paid; overdue flag; overpayment blocked |
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

- Not done yet: batch/lot tracking, quotations (enquiry → quote → order), GST (HSN codes, CGST/SGST/IGST), quality-control records,
  customer replacement reminders, credit notes and PDF export of invoices and payslips.
- Single currency (INR) and a single company.
- Sessions are kept in server memory, so everyone is signed out when the server restarts.
- Serve it over HTTPS (for example behind a reverse proxy) before exposing it beyond a local network.

## Credits

The module list follows the common ERP structure used by open-source systems such as Odoo and MyCompany (lsFusion).
No code from those projects is used; the schema, logic and screens in this repository were written for StockMate.

next

