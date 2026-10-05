# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A data project, not a software package: cleaned NCAA women's college basketball rosters (one CSV per season, 2020-21 onward) plus a stable cross-season player ID. Original roster scrapes live in a separate repo (`github.com/dwillis/wbb-rosters`, one raw CSV per season); this repo holds the cleaned/standardized outputs, built in R Markdown. Maintained for the Sports Roster Data project at the University of Maryland — credit that name in any published use.

## Commands

There is no build system, test suite, or linter. "Building" means knitting the R Markdown notebooks (R and `Rscript` are on PATH; packages needed: tidyverse, janitor, postmastr, usdata, rvest, stringdist, stringi):

```r
# Main per-season cleaning pipeline (reads from the web, writes wbb_rosters_<season>.csv)
Rscript -e "rmarkdown::render('cleaning.Rmd')"

# Cross-season player ID pipeline (reads all season CSVs, writes players.csv, etc.)
Rscript -e "rmarkdown::render('player_ids.Rmd')"
```

Data quality checking is done inside the notebooks — `cleaning.Rmd` ends with a **Data quality checks** section, and `player_ids.Rmd` runs validation + spot checks. `stopifnot()` calls act as pipeline guards; their error message strings tell you which invariant broke. Don't weaken them to make a run pass.

Cleaning must be done for seasons **in chronological order**: `cleaning.Rmd` backfills missing high schools from the previous season's output file (`PREV_FILE`), so season N depends on season N-1's CSV already existing.

## Architecture: the data pipeline

### 1. Season cleaning — `cleaning.Rmd`

Single configuration knob at the top: `SEASON` (e.g. `"2026-27"`); `SEASON_TAG`/`PREV_FILE`/URLs all derive from it. It also downloads team metadata from `teams.csv` (in this repo, committed) and pulls raw rosters from `INPUT_URL` (external repo), so knitting requires internet access.

Pipeline order, each in its own chunk: heights (`5'10"`-style → `height_ft/height_in/total_inches`, values outside 58–90 inches set to NA as parse errors); positions (lookup CSV + token fallback → `primary_position`/`secondary_position`); class years (exact lookup in `years_cleaned.csv` [columns `year`, `year-clean`, `redshirt`] + pattern fallback + graduation-year map → `year_clean`/`redshirt`); high school vs. previous school disentangling + cross-season high school backfill; hometown parsing via postmastr → `state_clean`/`country_clean` (long curated case_when lists for state abbreviations and country variants); high school standardization (see below); previous-school abbreviation mapping. Final chunk dedupes (one row per team+ncaa_id+name+jersey), asserts row counts, and writes `wbb_rosters_<season>.csv` with `quote = "all"` — keep that convention for all output CSVs.

### 2. Cross-season player IDs — `player_ids.Rmd` + `scripts/player_id_functions.R`

The season files' own `player_id` is a roster number that changes every season (and vanished in 2025-26), so `player_id_functions.R` builds `wbb_id` (`wbb-%06d`, stable across seasons and teams) by processing each season in order against a cumulative player table:

- **Tier 1**: same normalized name + same team, passing class-year progression and height checks.
- **Tier 2**: transfer — same name on a different team, corroborated by `previous_school_clean` matching the prior team, or matching hometown+state or high school.
- **Tier 3**: fuzzy (name distance + blocking) — **never auto-merged**; written to `wbb_id_review_queue.csv` for human adjudication.
- Cross-team same-name pairs with **no** corroborating evidence that still pass the year/height screens are queued too (`same_name_unconfirmed_transfer`), as are corroborated pairs that fail a screen (`corroborated_blocked`, with the evidence and the failing screen recorded). Neither is ever auto-merged.
- Within-season same-name duplicates: auto-merged only when hometown AND height agree; otherwise sent to the review queue.
- Class-year progression allows known special cases (redshirts; the 2020-21→2021-22 COVID eligibility freeze).

Human decisions go in `player_id_overrides.csv` (`season_a/team_a/name_a`, `season_b/team_b/name_b`, decision `same`/`different`) and are re-applied on every re-knit, so adjudication persists across seasons. The 2022-23 GUID crosswalk (`wbb_rosters23_crosswalk.csv`) serves as independent within-season ground truth (precision/recall check).

Outputs: `players.csv` (one row per `wbb_id`, mode-value attributes), `wbb_player_seasons.csv` (season-level links), `wbb_rosters_combined.csv` (all seasons joined with `wbb_id` appended), `wbb_id_review_queue.csv`.

### 3. High school standardization — `data/high_school_mapping.csv`

Mapping of raw → canonical high school names with a `confidence` column (`high_auto`, `high_manual`, `medium_nces`, `low_fuzzy`, `international`), built by the Python scripts in `scripts/`. `cleaning.Rmd` applies the mapping **inline** in its own chunk (that is the authoritative version); `scripts/apply_hs_standardization.R` is a standalone duplicate kept for reference. `data/high_school_mapping.csv` is committed; other `data/high_schools_*.csv` analysis files are gitignored.

⚠️ `scripts/normalize_high_schools.py` and `scripts/build_hs_mapping.py` both `import hs_standardization` — **that module does not exist in the repo**, so both scripts fail. Rebuilding the mapping requires reconstructing it (see HIGH_SCHOOL_STANDARDIZATION.md for its functions) or supplying the missing file.

### 3b. Previous-school standardization — `data/previous_school_mapping.csv`

Same pattern for previous schools, self-contained stdlib-only builder: `scripts/build_prev_school_mapping.py` (unlike the HS scripts, no missing module) → `data/previous_school_mapping.csv` (columns `previous_school`, `canonical`, `ncaa_id`, `category` (`roster_team`/`juco`/`prep`, blank until adjudicated), `confidence`). Stages: `high_auto` token-equality exact matches (abbreviation-expanded) against `teams.csv` names + a curated JuCo list + prep-school tokens; `low_fuzzy` difflib ≥ 0.85 matches, audited per row (wrong ones are blanked and embedded as `AUDIT_BLANKS` in the builder so re-runs stay audited); `manual` for the rest. `player_ids.Rmd` applies it in the ID layer (`load_prev_school_map`/`ps_map_lookup` in `player_id_functions.R`): `previous_school_lookup` (raw `previous_school`, else `previous_school_clean`) gets `previous_school_canonical` — which falls back to the raw lookup string for still-manual rows — plus `previous_school_ncaa_id`/`previous_school_category`; tier 2 then matches on `previous_school_ncaa_id == prior team's ncaa_id` first, normalized-string equality second. Re-run the builder after any new season lands, then re-knit `player_ids.Rmd`.

### 4. Manual corrections — `editor/` + `corrections/`

Per-player fixes made in the Flask editor (`editor/app.py`, one server for every `wbb_rosters_YYYY_YY.csv`, season chosen per request via `?season=`; Tabulator grid in `editor/static/index.html`) are logged one row per changed cell (or deleted row) in `corrections/corrections_<season_tag>.csv`, keyed on the **as-scraped** `ncaa_id, team, name, jersey`. Two implementations apply the log and must stay in sync: `editor/corrections.py` (`apply_corrections`) and the `apply-corrections` chunk of `cleaning.Rmd`. Both start from `corrections/baseline_<season_tag>.csv` (uncorrected output, written by every knit, gitignored) and must produce byte-identical CSVs. Both take the **first** row when a key repeats (R's `match()`); the editor refuses to correct rows with a repeated key. Python reads and writes the CSV with a custom parser because R's `quote = "all"` leaves numbers, logicals and NAs bare and writes empty strings as `""`. Tests: `editor/.venv/bin/python -m pytest editor/tests`.

Knit with a UTF-8 locale (`LANG=en_US.UTF-8 Rscript ...`). Under the C locale the non-ASCII literals in `cleaning.Rmd`'s case_when lists ("TÜRKIYE", "QUÉBEC") silently fail to match.

### 5. Other directories

- `teams.csv` — canonical team metadata (`ncaa_id` is the join key everywhere; `team`, `team_state`, `conference`, `division`). Fix team errors here, not in the roster files.
- `coaches/` — a separate coaching-history dataset (`coaches_with_history.csv`) with its own README and notebook; `team_id` here is the same `ncaa_id`.
- `exploration.Rmd`, `prep.qmd` — ad-hoc analysis/one-off prep, not part of the pipeline.

## Annual new-season workflow

1. Set `SEASON` in `cleaning.Rmd` and knit it; review the quality-check sections. (`cleaning.Rmd` requires `PREV_FILE` — last season's CSV — to already exist.)
2. Add the new season's CSV to `SEASON_FILES` in `scripts/player_id_functions.R`, knit `player_ids.Rmd`, then adjudicate `wbb_id_review_queue.csv`: fill its `decision` column, copy resolved pairs into `player_id_overrides.csv`, and re-knit so overrides take effect across seasons.
3. Commit the new season CSV plus the rebuilt `players.csv`, `wbb_player_seasons.csv`, `wbb_rosters_combined.csv`, and review queue.

## Known source-corruption landmines

Read `DATA_QUALITY_ISSUES.md` before writing new parsing code: ~5 roster rows have structurally shifted fields (a missing field shifts every downstream column left), and the worst case — an unescaped `5'10""` height string — breaks CSV quoting and swallows the entire next row into the previous record. When a new season shows one-row-off values or a vanished neighbor row, check for this pattern in the raw scrape first; the scraper is in `dwillis/wbb/blob/master/ncaa/rosters.py`.

The raw data is intentionally messy upstream: heights, positions, class years (including graduation years like "2030"), and hometown spellings all need the case_when/lookup scaffolding in `cleaning.Rmd`; extend those tables (`years_cleaned.csv`, position fallback, state/country case_when lists) rather than adding one-off fixes elsewhere.