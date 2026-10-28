# Geography division dropdowns (2026-10-04)

## Problem

The geography views count every division together, so they show overall patterns only. Division I and Division III recruit from very different state/country footprints, and the in-state recruiting view already has a Division dropdown — the other four views can't answer "who does Division II actually pull from?"

## Design

Every geography view is self-contained (its own controls, chart, table, CSV, takeaway). The four views that lack a division control get one, each following the figures through everything it affects.

### Data build (`scripts/build_site_data.R`)

Three new aggregates in `geography.json`, each bucketed by the roster row's own `division` (a team's division can change across seasons; blank → a `"Unknown"` bucket that the UI never offers):

- `state_season_division` — division → state code → per-season counts (same shape as `state_season`)
- `country_season_division` — division → country → per-season counts, **all countries** (not a top-N; clients derive leaders per division)
- `cities_division` — division → city+state → distinct players and player-seasons (all seasons), with the ≥10-distinct-players threshold applied **within each division** — a city passing overall but not within one division drops from that division's view, and vice versa

Per-capita rates at division level divide by the same full-state 2020 Census population (rate of e.g. Division I players per 1M residents). `stopifnot()` guards: per-division state matrices sum exactly to the overall state-row total; country matrices sum to all rows. The existing overall matrices are reused unchanged for "All divisions", so overall figures are byte-identical to today's. JSON cost ≲30 KB raw.

### UI (`site/js/geography.js`)

Views 1–4 each get `App.select({label:'Division'})` beside their existing controls, options **All / Division I / Division II / Division III**. NAIA is deliberately **not offered** in the new dropdowns (35 rows); those rows appear only under All, matching overall today. (The pre-existing in-state view keeps offering NAIA — not touched. Blank-division rows are "Unknown" and excluded from division views everywhere.)

- **Choropleth** — `stateCount`/`statePercap`/`measureSort` gain a division argument; Measure (count ↔ per 1M), Season, the shaded map, the all-states table, the CSV and the takeaway line all follow the selected division. The chart subtitle states the division.
- **International over time** — the top-8 countries are recomputed per division at update time (not frozen at render); in share mode the denominator is that division's total that season; the muted "All international" context line tracks the selection.
- **Country treemap** — country values per division; leader/share text follows; "include USA" toggle unchanged.
- **Hometown hotbeds** — top-25 chart and full city table rebuild from `cities_division`; the sub explains the distinct-players rule ("a player who crossed divisions counts in both").
- **In-state recruiting** — unchanged (already division-filtered).

### Verification

Build guards fail loudly if division figures don't reconcile. Headless-Chrome checks per view against figures computed independently from the new JSON (choropleth table order per division, intl top-8, treemap totals), plus the All-divisions parity check (identical output to pre-change). `node --check` per convention; deploy via the Pages workflow and verify live.