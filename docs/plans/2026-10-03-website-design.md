# Public roster site design (2026-10-03)

## Problem

The cleaned rosters live in committed CSVs that only an R user can explore. There is no public face for the dataset: no way to search a season, look up a player across seasons, or see the patterns in the data (international players, transfers, class-year mix) without cloning the repo.

## Design

A static site on GitHub Pages (`https://sports-roster-data.github.io/womens-college-basketball/`), built for journalists and researchers: search/lookup/download/cite first, visual exploration second. No Node, no bundler — R stays the only data language, and the site reuses the editor's design language (stone/blue, system-ui, Tabulator from cdnjs).

### Data build

`scripts/build_site_data.R` (jsonlite + base R) reads `wbb_rosters_combined.csv`, `players.csv` and `teams.csv` from the repo root and writes JSON to `site/data/`:

- `seasons/<season>.json` — one file per season, the 18 columns the UI needs, as compact arrays with a `cols` map. Fetched on demand by the explorer.
- `players.json` — 39K-player search index (id, name, seasons span, position, hometown), fetched on first search.
- `cards/wbb-00.json` … `wbb-39.json` — 40 shards of per-player cards (season-by-season timeline), fetched per player page.
- `teams.json`, `team_seasons.json` — team metadata and per-team-per-season summaries (in-state %, transfers in/out, retained).
- `geography.json`, `transfers.json`, `trends.json` — precomputed aggregates for the three chart bundles.
- `meta.json` — seasons, totals, state populations (2020 Census), dropdown option lists.

Seasons are **derived from the combined file**, never hardcoded — when a future re-knit of `player_ids.Rmd` adds 2026-27, the next build picks it up with no code change. The build dedupes the 61 flagged duplicate `(wbb_id, season)` rows (keeping the most complete), normalizes `USVI` → `VI`, compares teams by `ncaa_id` (names change; ids don't), and ends with `stopifnot()` guards: player counts match `players.csv`, totals reconcile, no duplicate player-seasons survive, unknown state codes stop the build. Generated JSON is gitignored — the CSVs stay the single source of truth, and the site deploys by rebuilding from them.

### Site

One HTML shell (`site/index.html`) with hash routing — deep links work with zero server config on the Pages subpath: `#/roster/2024-25?state=TX`, `#/player/wbb-001155`, `#/team/<ncaa_id>`, plus `#/geography`, `#/transfers`, `#/trends`, `#/about`.

- **Roster Explorer** — season picker, Tabulator grid with per-column filters (team, conference, division, state, country, position, class year), live count, and "download this filtered view as CSV". Every filtered view is a permalink via the hash.
- **Player search** — cross-year: type a name, get every season she played with each team, class year and height; transfer moves visible in the timeline. Cards get stable `#/player/<wbb_id>` links.
- **Team pages** — header, per-season summary strip (players, in-state %, transfers, retained %), drill links into the explorer.
- **Three chart bundles** (ECharts, same palette discipline across all charts, CSV download on every view):
  - *Geography* — US hometown choropleth (count ↔ per-capita toggle), international players over time, country treemap, hometown hotbeds, in-state recruiting %.
  - *Transfers* — season-over-season flows via `wbb_id`: conference and team Sankeys, most-traveled players, feeder programs, roster turnover. Transfer counts are a floor — tier-3 fuzzy matches await human adjudication, and the pages say so.
  - *Trends* — class-year composition (the COVID freeze is visible), height distribution, position mix, roster scale.
- **About** — required credit ("Sports Roster Data project at the University of Maryland"), data dictionary for the shipped columns, download links to the committed CSVs, known limitations.

### Deployment

`.github/workflows/pages.yml` builds the JSON on every push to `main` that touches the data or the site, and deploys `site/` to Pages. One-time manual step: repo Settings → Pages → Source = "GitHub Actions".

## Out of scope

Fun stats (names, jersey numbers, height extremes — cheap to add later); the coaches dataset; dark mode; per-player statistics beyond roster facts; geocoded hometown-to-campus distances.

## Risks

Pages must be enabled by hand before the first deploy works. Transfer and feeder counts depend on cross-season matching quality and carry a floor caveat on-page. City extraction from `hometown_clean` is best-effort (spelling variants like "CHICAGO, ILL"), documented where shown. The map geometry ships as a committed Census-derived GeoJSON (`site/data/us-states.json`, ~89KB); Tabulator and ECharts load from cdnjs, matching the editor.