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
Grafana Git Sync picks it up and the **Workout Analytics** dashboard appears in its folder.
It has 5 collapsible rows: **Overview**, **Deep Dive** (filter-driven), **By Muscle Group**,
**Consistency**, **Bodyweight**.

## Notes
- **Variables** (top of the dashboard) form a drill-down, all defaulting to **None** so the
  Deep Dive starts empty (not hectic): `$area` (general group — Legs / Chest / Back /
  Shoulders / Arms / Core), `$muscle` (specific muscle — quads, hamstrings, …), `$exercise`,
  plus `$set_type` (working / all / warm-up, default working) and `$score_basis` (heaviest vs
  average) which toggles the custom Strength Score. Filter precedence is exercise > muscle >
  area, so pick whichever level you want.
- All variables are **custom (static) lists**, not datasource queries — this is deliberate so
  the dropdowns work on **public / externally-shared dashboards** (anonymous viewers can't run
  variable queries). Trade-off: the `$muscle` and `$exercise` lists are the full sets (13 and
  ~122, both searchable) and don't auto-narrow to the selected area. **If you add new
  exercises, re-generate these lists** (they're baked into `workout-insights.json`).
- **Custom Strength Score** = pounds lifted ÷ nearest-date bodyweight, plotted over time.
  `heaviest` uses your top working set; `average` uses the mean working-set load (smoother).
  Rising while bodyweight falls = getting relatively stronger.
- **Strength Curve** = heaviest weight at each rep count; pick one exercise for a clean
  drop-off curve to plan working weights.
- These use the Grafana v2 variable schema. If a variable ever misbehaves after a Grafana
  upgrade, open dashboard settings → Variables in the UI, re-save, and commit the export —
  the panel/layout structure matches riftbound's, so only the variables are novel.
- **Annotations**: your `workout.notes` render as yellow vertical markers.
- Default time range is the **last 1 year**; widen it for full history (data starts
  2023-02-25).
- This dashboard is fully independent: its own Neon database, its own datasource, its own
  `workout` schema. It shares nothing with any other dashboard.
