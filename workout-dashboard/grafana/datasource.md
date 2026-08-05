# Wiring Grafana (Git Sync) for the workout dashboard

The dashboard resource lives at **`dashboards/workout-insights.json`** (repo root), in the
`dashboard.grafana.app/v2` format — the same format and folder your riftbound dashboard uses.
Grafana **Git Sync** provisions it automatically once it's committed with a real datasource UID.

Unlike a manual import, a Git-synced dashboard references its Postgres datasource **by UID**
baked into the JSON — there's no import-time datasource picker. So the one manual step is
replacing the placeholder UID.

## 1. Create the datasource
1. Create a **new Neon database** for the workout data (kept separate from riftbound).
   Run the loader against it (see the main [README](../README.md)).
2. In Grafana → **Connections → Data sources → Add data source → PostgreSQL**, fill in the
   Neon host/db/user/password, **TLS/SSL Mode = require** (Neon requires TLS), **Save & test**.
3. Copy the datasource's **UID**: open the datasource and take it from the browser URL
   (`/connections/datasources/edit/<UID>`), or from its settings.

## 2. Point the dashboard at it
The dashboard ships with the placeholder `REPLACE_WITH_DS_UID` (31 occurrences: every panel
query, the annotation query, and the `$exercise` variable). Replace them all with your UID:

```bash
# from the repo root, on macOS:
sed -i '' 's/REPLACE_WITH_DS_UID/YOUR_DS_UID_HERE/g' dashboards/workout-insights.json
```
(On Linux/Git-Bash drop the `''`: `sed -i 's/.../g' ...`.)

## 3. Commit → sync
```bash
git add dashboards/workout-insights.json
git commit -m "Point workout dashboard at its Neon datasource"
git push
```
Grafana Git Sync picks it up and the **Workout Analytics** dashboard appears in the same
folder as riftbound. It has 6 collapsible rows (Overview, Consistency, Volume & Endurance,
Strength & All-Time Highs, Bodyweight-Relative Strength, Balance).

## Notes
- **Variables**: `$exercise` (deep-dive), `$set_type` (working / all / warm-up, default
  working), `$bodyweight_lift` (strength-score series). These use the Grafana v2 variable
  schema. If a variable ever misbehaves after a Grafana upgrade, the quickest fix is to open
  the dashboard settings → Variables in the UI, confirm/re-save, and commit the exported
  result back — the panel/layout structure is a byte-for-byte match of riftbound's, so only
  the variables are novel here.
- **Annotations**: your `workout.notes` render as yellow vertical markers.
- Default time range is the **last 1 year**; widen it for full history (data starts
  2023-02-25).
- This dashboard is fully independent: its own Neon database, its own datasource, its own
  `workout` schema. It shares nothing with any other dashboard.
