# Wiring the Neon Postgres data source in Grafana

The dashboard queries the `workout` schema through a **PostgreSQL** data source.

## 1. Add the data source
Grafana → **Connections → Data sources → Add data source → PostgreSQL**, then fill in
the values from your Neon connection string
(`postgresql://USER:PASSWORD@HOST/DBNAME?sslmode=require`):

| Field | Value |
|---|---|
| **Host** | `ep-xxxx-xxxx.us-east-2.aws.neon.tech:5432` (the host from the URL, `:5432`) |
| **Database** | `neondb` (or your DB name) |
| **User** | the user from the URL |
| **Password** | the password from the URL |
| **TLS/SSL Mode** | **require** |
| **PostgreSQL version** | 15+ |

> Neon requires TLS. If Grafana can't connect, make sure **SSL Mode = require** (not
> disable) and that you're using the *pooled* or *direct* host consistently.

Leave "With CA cert" off — `require` verifies transport encryption without a custom CA.

Click **Save & test** → you should see *"Database Connection OK"*.

## 2. Import the dashboard
Grafana → **Dashboards → New → Import** → upload `grafana/dashboard.json` (or paste it).
When prompted for **DS_POSTGRES**, pick the PostgreSQL data source you just created, then
**Import**.

Because the dashboard uses a `${DS_POSTGRES}` datasource variable, it's fully portable —
no hard-coded datasource UID.

## 3. Notes
- The dashboard defaults to the **last 1 year**; widen the time picker for full history
  (data starts 2023-02-25).
- Variables at the top: **Exercise** (deep-dive), **Set type** (working / all / warm-up),
  **Big lifts** (strength-score series). "Working" excludes warm-up sets.
- Yellow vertical markers are your **workout notes** (from `workout.notes`).
- All panels read from the `workout.v_*` views created by `sql/002_views.sql`, so if you
  tweak a metric you usually only edit a view, not every panel.
