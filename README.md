# sf-admin-dash (Stellar Forge platform repo)
Owns the shared database (`supabase/migrations`), the DB deploy workflow, and the admin dashboard.

## Deploy
1. Push this folder to a new GitHub repo.
2. Vercel -> Add New Project -> import the repo (framework: Vite, auto-detected). Add the variables from `.env.example`. Every push to `main` deploys.
3. GitHub -> Settings -> Secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD`.
   Pull requests run the isolation test; pushes to `main` apply new migrations after the test passes.
4. Create the two admins (no signup exists):
   `node -e "const c=require('crypto');const s=c.randomBytes(16).toString('hex');console.log(s,c.scryptSync('PASSWORD',s,64).toString('hex'))"`
   then in the Supabase SQL editor: `insert into platform_admins values ('email','<salt>','<hash>');`
5. Never edit a migration that has been applied. Add a new numbered file instead.

## Review reminders
Add GitHub secrets `CRON_SECRET` and `ADMIN_DASH_URL`. `.github/workflows/reminders.yml` then emails both admins
30 minutes before and at the 1-hour review deadline (once each per shop).

## Migrations
- `0001_core.sql` shops, trials, admin tables, per-shop isolation.
- `0002_billing_compat.sql` bill numbering, snapshots, printed-bill locks and storage buckets for the billing app.
- `0003_expense.sql` Expense Tracker tables, per-shop sync from billing, per-product trials.
Run order is automatic. Never edit an applied migration; add `0003_...`.
