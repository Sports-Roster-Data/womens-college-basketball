# Geography division dropdowns — implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A Division dropdown on the choropleth, international-over-time, country-treemap and hotbeds views of `#/geography`, with per-division figures computed in `build_site_data.R`.

**Architecture:** The build script emits three new per-division aggregates alongside the existing overall ones (which stay byte-identical and back "All divisions"). Each view keeps its own `App.select` Division control wired to its `*Update()` function; tables, CSVs and takeaways follow the selection. Design: `docs/plans/2026-10-04-geography-division-design.md`.

**Tech Stack:** R + jsonlite (build), vanilla JS + ECharts + Tabulator (site), headless Chrome `--dump-dom` for verification.

**Conventions:** UTF-8 locale for Rscript; `node --check` for JS; all commits end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

---

### Task 0: capture the pre-change baseline

**Step 1:** Copy the current generated JSON so the "All divisions = byte-identical" check has a reference (it is rebuilt, not committed):

```bash
cp site/data/geography.json /tmp/geo_before.json
```

**Step 2:** Confirm it matches production (this build came from the same committed CSVs):

```bash
jq -c '.state_season.PA' site/data/geography.json   # expect [counts]; just eyeball non-empty
```

### Task 1: per-division aggregates in the build script

**Files:**
- Modify: `scripts/build_site_data.R` (geography chunk, after each existing matrix is built and in the final `wj()` list)
- Test: run the script; guards + python parity check

**Step 1: division-aware state matrix** — insert right after the `state_season` lapply block and its reconciliation guard (`state matrix doesn't reconcile...`):

```r
# Per-division state matrix, bucketed by the row's own division (blank ->
# "Unknown"; "NAIA" passes through but is not offered in the UI). The overall
# state_season above stays the "all divisions" source, so overall figures
# never shift.
division_of <- ifelse(is.na(us_state_rows$division) | us_state_rows$division == "",
                      "Unknown", us_state_rows$division)
div_levels <- sort(unique(division_of))
state_season_division <- lapply(div_levels, function(dv) {
  keep <- division_of == dv
  lapply(state_levels, function(st) {
    as.integer(table(factor(us_state_rows$season_idx[us_state_rows$state_clean == st & keep],
                            levels = 0:(n_season - 1))))
  })
})
names(state_season_division) <- div_levels
stopifnot("division state matrices don't reconcile with overall state rows" =
            sum(unlist(state_season_division)) == nrow(us_state_rows))
```

**Step 2: division-aware country matrix** — insert right after the `country_season` guard (`country matrix doesn't reconcile with total rows`):

```r
# Per-division country matrix over ALL countries; the client derives per-
# division leaders from it.
division_of_all <- ifelse(is.na(w$division) | w$division == "", "Unknown", w$division)
div_levels_all <- sort(unique(division_of_all))
country_season_division <- lapply(div_levels_all, function(dv) {
  keep <- division_of_all == dv
  lapply(country_levels, function(co) {
    as.integer(table(factor(w$season_idx[country_of == co & keep],
                            levels = 0:(n_season - 1))))
  })
})
names(country_season_division) <- div_levels_all
stopifnot("division country matrices don't reconcile with total rows" =
            sum(unlist(country_season_division)) == n_rows)
```

**Step 3: per-division cities** — insert right after the overall `cities` frame is ordered (`rownames(cities) <- NULL`) and before its `cat()` line:

```r
# Per-division city lists: threshold applied within each division, so a city
# that passes overall but not within one division drops from that division's
# view. Same [city, state, players, rows] shape as `cities`.
us_h_div <- ifelse(is.na(us_h$division) | us_h$division == "", "Unknown", us_h$division)
cities_division <- lapply(sort(unique(us_h_div)), function(dv) {
  hd <- us_h[us_h_div == dv, ]
  city_d <- vapply(hd$hometown_clean, city_from, "", USE.NAMES = FALSE)
  key_d <- paste(city_d, hd$state_clean, sep = "\r")
  f_d <- factor(key_d)
  out <- data.frame(
    city = vapply(strsplit(levels(f_d), "\r", fixed = TRUE), `[[`, "", 1),
    state = vapply(strsplit(levels(f_d), "\r", fixed = TRUE), `[[`, "", 2),
    players = as.integer(tapply(hd$wbb_id, f_d, function(v) length(unique(v)))),
    rows = as.integer(table(f_d)),
    stringsAsFactors = FALSE
  )
  out <- out[out$players >= CITY_MIN_PLAYERS, ]
  out <- out[order(-out$players, out$city, method = "radix"), ]
  rownames(out) <- NULL
  out
})
names(cities_division) <- sort(unique(us_h_div))
```

**Step 4: ship them** — extend the `wj()` call for geography.json:

```r
wj(list(
  state_season = state_season,
  country_season = country_season,
  season_totals = season_rows,
  cities = cities,
  state_season_division = state_season_division,
  country_season_division = country_season_division,
  cities_division = cities_division
), "site/data/geography.json")
```

**Step 5: run the build**

```bash
LC_ALL=en_US.UTF-8 Rscript scripts/build_site_data.R 2>&1 | tail -6
```

Expected: no guard failure, `Done.` with the size report (geography.json grows).

**Step 6: parity check — "All" must equal the pre-change file**

```bash
python3 - <<'EOF'
import json
a = json.load(open('/tmp/geo_before.json')); b = json.load(open('site/data/geography.json'))
assert a['state_season'] == b['state_season'] and a['country_season'] == b['country_season']
assert a['cities'] == b['cities'] and a['season_totals'] == b['season_totals']
sd = b['state_season_division']; total = sum(sum(v) for d in sd.values() for v in d.values())
assert total == sum(v for arr in b['state_season'].values() for v in arr)
print("parity OK; divisions:", sorted(sd), "; I total rows:",
      sum(v for v in sd['I'].values() for _ in [0]) if 'I' in sd else 0)
EOF
```

Expected: `parity OK; divisions: ['I', 'II', 'III', 'Unknown', 'NAIA'] …`

**Step 7: commit**

```bash
git add scripts/build_site_data.R && git commit -m "Site data: per-division geography aggregates

state/country season matrices and city lists bucketed by roster-row
division; overall matrices unchanged (All-divisions parity guarded).
Guards assert per-division sums reconcile with overall totals."
```

### Task 2: choropleth division dropdown

**Files:**
- Modify: `site/js/geography.js` (view 1: state vars, helpers, mapUpdate, group controls, chartSub node, CSV)
- Test: node --check + headless Chrome dump vs independently computed order

**Step 1: helpers gain a division argument** (replace `stateCount`/`statePercap`/`measureSort` and the `mapState` line):

```js
var mapState = { mode: 'percap', season: -1, division: 'all' }; // -1 = all seasons
…
function stateCount(code, seasonIdx, division) {
  var m = (division && division !== 'all') ? geo.state_season_division[division] : geo.state_season;
  var arr = m[code];
  if (!arr) return 0;
  if (seasonIdx < 0) return arr.reduce(function (a, b) { return a + b; }, 0);
  return arr[seasonIdx] || 0;
}
```
`statePercap`/`measureSort` take `mapState.division` the same way (`statePercap(code, s, div)`, comparator passes `mapState.division` through to both helpers). Every `stateCount(x, y)` call inside `mapUpdate` becomes `stateCount(x, y, mapState.division)` — including the tooltip formatter's `r.count` source (the `rows` array already carries `count`), the table body, the CSV, and the takeaway's `leadCount`.

**Step 2: wire the control + subtitle** — in the `group([...])` call, add as the FIRST control:

```js
App.select({
  label: 'Division', value: mapState.division,
  options: [{ value: 'all', label: 'All' }].concat(
    App.meta.filter_options.division.filter(function (d) { return d === 'I' || d === 'II' || d === 'III'; })
      .map(function (d) { return { value: d, label: 'Division ' + d }; })),
  onchange: function (v) { mapState.division = v; mapUpdate(); }
}),
```

Hold the subtitle node (`var mapSub = chartSub('…');`) — keep the existing static text but end it before appending; inside `mapUpdate`, first line:

```js
mapSub.textContent = 'Players whose hometown has a US state, by state, ' +
  (mapState.division === 'all' ? 'all divisions' : 'Division ' + mapState.division) +
  (unmapped.length ? ' — * marks ' + unmapped.map(function (c) { return statesMeta[c].name; }).join(', ') +
    ', which are not drawn on the map' : '') + '.';
```

**Step 3: CSV gains a self-describing division column** — header becomes
`['division', 'state', 'name', 'players', 'per_1m_residents']`, each row leads with
`(mapState.division === 'all' ? 'all' : mapState.division)`.

**Step 4: verify**

```bash
node --check site/js/geography.js
# serve :8003, Chrome dump-dom http://localhost:8003/site/#/geography
python3 - <<'EOF'
# parse the first table after 'Where US players come from'; assert row order =
# per-capita order computed from geo.state_season_division['I'] + meta states;
# assert subtitle text contains 'Division I' after a Division I selection is
# simulated only if a control-click harness exists — otherwise verify the
# 'all' default renders byte-identically to today (parity).
EOF
```
Expected: default view unchanged vs `/tmp/geo_before`-derived order; Division I order matches python-computed per-capita order from the division matrix (checked by temporarily selecting the option via a scripted DOM check in Chrome `--headless --repl` is unavailable — instead assert on the DUMP that the select's options exist and default `selected`; then re-run the dump reading `#/geography` with a temporary `mapState.division` default flipped locally, discarded before commit).

**Step 5: commit**

```bash
git add site/js/geography.js && git commit -m "Geography: Division dropdown on the US choropleth

Map shading, measure radio, table twin, CSV and takeaway all follow
the selected division; per-capita still divides by full-state
population. All/overall figures unchanged."
```

### Task 3: international view division dropdown

**Files:**
- Modify: `site/js/geography.js` (view 2: `nonUSA`/`top8` become per-division; share denominator; takeaway; CSV)

**Step 1:** Replace the render-time `nonUSA`/`top8` constants with per-division derivations inside `intlUpdate()`:

```js
var intDiv = 'all';
function countryCount(c) {  // total across seasons for the selected division
  var m = (intDiv && intDiv !== 'all') ? geo.country_season_division[intDiv] : geo.country_season;
  return (m[c] || []).reduce(function (a, b) { return a + b; }, 0);
}
function seasonTotal(i) {   // denominator for share mode
  if (intDiv !== 'all') return Object.keys(geo.country_season_division[intDiv])
    .reduce(function (a, c) { return a + geo.country_season_division[intDiv][c][i]; }, 0);
  return geo.season_totals[i];
}
function top8Now() {
  var m = (intDiv !== 'all') ? geo.country_season_division[intDiv] : geo.country_season;
  return Object.keys(m).filter(function (c) { return c !== 'USA'; })
    .sort(function (a, b) { return countryCount(b) - countryCount(a); }).slice(0, 8);
}
```
`intlUpdate()` uses `top8Now()` for the series (with the `'All international'` context line summing `countryCount`-style per season via `seasonTotal`-sibling logic: sum over non-USA keys of the active matrix), share values use `seasonTotal(i)`, axis name and takeaway text state the division (`', Division ' + intDiv` clauses). Render-time `allIntl(i)` becomes `allIntl(i, div)` summing non-USA keys of the ACTIVE matrix.

**Step 2:** Division `App.select` as the second control (same options list as Task 2, value `intDiv`).

**Step 3:** CSV header `['division', 'season', …top8…, 'all_international']` with the current division value leading each row.

**Step 4:** `node --check`; Chrome dump: with default All, the top-8 must equal the overall top-8 from `/tmp/geo_before` (parity); the select exists with 4 options.

**Step 5: commit** — `git add site/js/geography.js && git commit -m "Geography: Division dropdown on international players view"`

### Task 4: treemap division dropdown

**Files:**
- Modify: `site/js/geography.js` (view 3)

**Step 1:** `var treeDiv = 'all';`; `countrySum(c)` per active division matrix (same helper shape as Task 3); `treeUpdate()` derives its list from the active matrix; takeaway gains the division clause.

**Step 2:** Division `App.select` after the US-toggle control.

**Step 3:** CSV `['division', 'country', 'player_seasons']`.

**Step 4:** `node --check`; dump check (leader text unchanged under All; select present).

**Step 5: commit** — `git add site/js/geography.js && git commit -m "Geography: Division dropdown on the country treemap"`

### Task 5: hotbeds division dropdown

**Files:**
- Modify: `site/js/geography.js` (view 4: hbUpdate, city Tabulator `setData`, subs, CSVs)

**Step 1:** `var hbDiv = 'all';` and a selector helper:

```js
function citiesNow() {
  return (hbDiv !== 'all') ? (geo.cities_division[hbDiv] || []) : geo.cities;
}
```
`hbUpdate()` builds `list` from `citiesNow()`; `hbTakeaway` gains the division clause; hotbeds subtitle node updates (division + the "a player who crossed divisions counts in both" rule).

**Step 2:** Division `App.select` as the second control; `onchange` also refreshes the city table: `cityTable.setData(citiesNow().map(...))` — so hoist `var cityTable;` above the group and build it after attach as today, mapping arrays to `{key, city, state, players, rows}` rows.

**Step 3:** Both CSVs (`cities_players.csv`, `cities_all.csv`) gain a leading `division` column.

**Step 4:** `node --check`; dump check: hotbeds leader under All equals today's; city table present.

**Step 5: commit** — `git add site/js/geography.js && git commit -m "Geography: Division dropdown on hometown hotbeds and city table"`

### Task 6: docs, full verification, deploy, live check

**Step 1:** Update `site/js/geography.js`'s header comment (views 1–4 now have a Division dropdown) and this repo's `site/README.md` layout line for geography.js if it mentions views ("choropleth, international lines, treemap, hotbeds, in-state %").

**Step 2:** Full local pass:

```bash
node --check site/js/geography.js && LC_ALL=en_US.UTF-8 Rscript scripts/build_site_data.R 2>&1 | tail -4
editor/.venv/bin/python -m pytest editor/tests -q
```

**Step 3:** Chrome dump of `#/geography` locally; python assertions: all four selects present (All default), choropleth table == parity order from `/tmp/geo_before.json`, takeaways carry no division clause under All.

**Step 4:** Commit any docs edits; push:

```bash
git push origin main
```

**Step 5:** Confirm the workflow run (use `gh run list --limit` — not `--commit=`, which failed to match push-event runs) then dump the LIVE geography page and re-run the Step 3 assertions against production.