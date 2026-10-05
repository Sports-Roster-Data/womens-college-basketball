"""Browser editor for the wbb_rosters_<season>.csv files.

    python editor/app.py              # opens on 2026-27; pick another season in the page
    python editor/app.py --season 2025-26

Edits are appended to corrections/corrections_<tag>.csv. After each save the
roster CSV is rebuilt as baseline + corrections, where the baseline
(corrections/baseline_<tag>.csv) is the uncorrected output that cleaning.Rmd
writes on every knit. cleaning.Rmd applies the same log the same way. A season
that has never been corrected gets its baseline copied from the roster CSV on
the first save.
"""

import argparse
import os
import re
import shutil
import sys
from datetime import datetime

from flask import Flask, jsonify, request, send_from_directory

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corrections as corr  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SEASON = "2026-27"
MAX_BATCH = 500
ROSTER_FILE = re.compile(r"wbb_rosters_(\d{4})_(\d{2})\.csv")

app = Flask(__name__, static_folder="static")
app.config.update(ROOT=ROOT, DEFAULT_SEASON=DEFAULT_SEASON)


class SeasonError(Exception):
    pass


class Paths:
    def __init__(self, season, root=ROOT):
        tag = season.replace("-", "_")
        self.season = season
        self.roster = os.path.join(root, f"wbb_rosters_{tag}.csv")
        self.log = os.path.join(root, "corrections", f"corrections_{tag}.csv")
        self.baseline = os.path.join(root, "corrections", f"baseline_{tag}.csv")


def available_seasons(root):
    seasons = []
    for f in os.listdir(root):
        m = ROSTER_FILE.fullmatch(f)
        if m:
            seasons.append(f"{m.group(1)}-{m.group(2)}")
    return sorted(seasons, reverse=True)


def season_paths():
    """Paths for the ?season= in the request (default season if absent)."""
    root = app.config["ROOT"]
    season = request.args.get("season") or app.config["DEFAULT_SEASON"]
    if season not in available_seasons(root):
        raise SeasonError(f"No roster file for season {season!r}.")
    return Paths(season, root)


def baseline_path(paths):
    """The baseline to apply corrections to; the roster itself while nothing is corrected."""
    if os.path.exists(paths.baseline):
        return paths.baseline
    if corr.read_log(paths.log):
        raise SeasonError(f"{os.path.basename(paths.baseline)} is missing but this season has corrections. "
                          "Knit cleaning.Rmd for this season to regenerate it.")
    return paths.roster


def ensure_baseline(paths):
    if baseline_path(paths) == paths.roster:
        os.makedirs(os.path.dirname(paths.baseline), exist_ok=True)
        shutil.copyfile(paths.roster, paths.baseline)


def current_state(paths):
    baseline = corr.read_table(baseline_path(paths))
    log = corr.read_log(paths.log)
    return log, *corr.apply_corrections(baseline, log)


def rebuild(paths):
    """Apply the full log to the baseline and rewrite the roster CSV."""
    _, table, _, report, _ = current_state(paths)
    corr.write_atomic(paths.roster, corr.format_table(table))
    return report


# ---------------------------------------------------------------- routes

@app.errorhandler(SeasonError)
def season_error(e):
    return _bad(str(e), 404)


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/seasons")
def seasons():
    return jsonify({"seasons": available_seasons(app.config["ROOT"]),
                    "default": app.config["DEFAULT_SEASON"]})


@app.get("/api/rows")
def rows():
    paths = season_paths()
    _, table, keys, report, touched = current_state(paths)
    ambiguous = corr.duplicate_keys(keys)
    out = []
    for i, (key, r) in enumerate(zip(keys, table.rows)):
        d = {c: corr.display(v) for c, v in zip(table.header, r)}
        d["_row"] = i
        d["_key"] = key
        d["_corrected"] = key in touched
        d["_ambiguous"] = key in ambiguous
        out.append(d)
    return jsonify({
        "season": paths.season,
        "columns": table.header,
        "numeric": sorted(table.bare),
        "locked": sorted(corr.LOCKED_COLUMNS),
        "rows": out,
        "report": report,
    })


@app.get("/api/batches")
def batches():
    log = corr.read_log(season_paths().log)
    grouped = {}
    for e in log:
        b = grouped.setdefault(e["batch_id"], {
            "batch_id": e["batch_id"], "note": e["note"], "edited_at": e["edited_at"],
            "actions": [], "columns": [], "count": 0, "players": []})
        b["count"] += 1
        for field, value in (("actions", e["action"]), ("columns", e["column"])):
            if value and value not in b[field]:
                b[field].append(value)
        if len(b["players"]) < 3:
            b["players"].append(f'{e["name"]} ({e["team"]})')
    return jsonify(sorted(grouped.values(), key=lambda b: b["batch_id"], reverse=True))


@app.post("/api/corrections")
def add_corrections():
    paths = season_paths()
    body = request.get_json(force=True)
    note = (body.get("note") or "").strip()
    items = body.get("rows") or []
    if not note:
        return _bad("A note is required.")
    if not items:
        return _bad("Nothing to save.")
    if len(items) > MAX_BATCH and not body.get("force"):
        return _bad(f"{len(items)} rows exceeds {MAX_BATCH}; resend with force to confirm.")

    log, table, keys, _, _ = current_state(paths)
    ambiguous = corr.duplicate_keys(keys)
    by_key = {}
    for k, r in zip(keys, table.rows):
        by_key.setdefault(k, r)
    idx = table.index
    batch_id = corr.new_batch_id()
    edited_at = datetime.now().isoformat(timespec="seconds")
    entries = []
    for item in items:
        key = item.get("_key", "")
        action = item.get("action", "set")
        if action not in corr.ACTIONS:
            return _bad(f"Unknown action {action!r}.")
        if key not in by_key:
            return _bad("A row was not found; reload the page.")
        ncaa_id, team, name, jersey = key.split("\t")
        if key in ambiguous:
            return _bad(f"{name} ({team}, jersey {jersey or 'blank'}) appears more than once in this "
                        "season's file, so a correction can't tell the rows apart. Fix the duplicate in cleaning.Rmd.")
        entry = {"season": paths.season, "ncaa_id": ncaa_id, "team": team, "name": name,
                 "jersey": jersey, "column": "", "old_value": "", "new_value": "",
                 "action": action, "batch_id": batch_id, "note": note, "edited_at": edited_at}
        if action == "set":
            col = item.get("column", "")
            if col not in idx:
                return _bad(f"Unknown column {col!r}.")
            if col in corr.LOCKED_COLUMNS:
                return _bad(f"{col} identifies the team and can't be edited.")
            try:
                new = corr.normalize_value(item.get("new_value"), col in table.bare)
            except ValueError as e:
                return _bad(f"{col}: {e}")
            old = by_key[key][idx[col]]
            if new == old:
                continue
            entry.update(column=col, old_value=corr.display(old), new_value=corr.display(new))
        entries.append(entry)
    if not entries:
        return _bad("No values changed.")

    ensure_baseline(paths)
    corr.write_log(paths.log, log + entries)
    report = rebuild(paths)
    return jsonify({"batch_id": batch_id, "saved": len(entries), "report": report})


@app.delete("/api/batches/<batch_id>")
def undo_batch(batch_id):
    paths = season_paths()
    log = corr.read_log(paths.log)
    kept = [e for e in log if e["batch_id"] != batch_id]
    if len(kept) == len(log):
        return _bad("No such batch.", 404)
    corr.write_log(paths.log, kept)
    report = rebuild(paths)
    return jsonify({"removed": len(log) - len(kept), "report": report})


def _bad(message, status=400):
    return jsonify({"error": message}), status


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--season", default=DEFAULT_SEASON, help="season the page opens on (default %(default)s)")
    p.add_argument("--port", type=int, default=5050)
    args = p.parse_args()
    seasons = available_seasons(ROOT)
    if args.season not in seasons:
        sys.exit(f"No wbb_rosters file for {args.season}. Available: {', '.join(seasons)}")
    app.config["DEFAULT_SEASON"] = args.season
    print(f"Seasons: {', '.join(seasons)}\nOpen http://127.0.0.1:{args.port}")
    app.run(host="127.0.0.1", port=args.port, debug=False)


if __name__ == "__main__":
    main()
