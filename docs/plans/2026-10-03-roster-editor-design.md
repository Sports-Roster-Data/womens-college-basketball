# Roster editor design (2026-10-03)

## Problem

`cleaning.Rmd` rebuilds `wbb_rosters_<season>.csv` from a fresh scrape on every knit, so hand edits to the CSV are lost. Fixes that apply to one player (a missing state, a wrong class year, a junk row) don't belong in the notebook's case_when tables either.

## Design

A local Flask app (`editor/`) shows the season CSV in a Tabulator grid. Three actions, each saved as one **batch** with a required note:

- edit cells (any number of edits, saved together),
- bulk set one column across the currently filtered rows,
- delete selected rows.

Every change is appended to `corrections/corrections_<season_tag>.csv`, one row per changed cell:

`season, ncaa_id, team, name, jersey, column, old_value, new_value, action (set|delete_row), batch_id, note, edited_at`

Rows are identified by the as-scraped `(ncaa_id, team, name, jersey)`, the same tuple `cleaning.Rmd` dedupes on. Renaming a player doesn't change her key, so later corrections still find her.

### Baseline + log

`cleaning.Rmd` writes its uncorrected output to `corrections/baseline_<season_tag>.csv`, then applies the log and writes the season CSV. The editor does the same on every save: season CSV = baseline + full log. Both implementations produce byte-identical files (verified on the 2026-27 season with a 104-correction log). Undoing a batch removes its rows from the log and rebuilds.

Applying a correction reports two problems without stopping:
- **unmatched**: the key isn't in the baseline (player renamed or dropped upstream),
- **stale**: the current value differs from `old_value` (the scrape changed since the edit); the correction is still applied.

R prints both in the knit output; the editor shows them in a banner.

### CSV fidelity

R's `write_csv(quote = "all", na = "")` quotes character values only, leaves numbers/logicals bare, writes NA as an empty field and an empty string as `""`. pandas and the `csv` module can't round-trip that, so `editor/corrections.py` has a small parser that keeps the distinction and infers which columns are bare. User input for numeric columns is normalized the way R would print it (`70.0` → `70`).

## Out of scope

Adding players; turning recurring bulk fixes into notebook case_when rules automatically; authentication (the server binds to 127.0.0.1).
