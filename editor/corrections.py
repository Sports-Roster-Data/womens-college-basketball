"""Read, apply and write roster corrections.

The roster CSVs are written by R's write_csv(quote = "all", na = ""), which
quotes character values, leaves numbers/logicals bare, writes NA as an empty
unquoted field and an empty string as "". The reader and writer here keep
those distinctions so output from Python is byte-identical to output from R.

A cell is a str, or None for NA.
"""

import csv
import io
import os
import re
import tempfile
from datetime import datetime
import secrets

KEY_COLUMNS = ["ncaa_id", "team", "name", "jersey"]
LOCKED_COLUMNS = {"ncaa_id", "team", "season"}
LOG_COLUMNS = ["season", "ncaa_id", "team", "name", "jersey", "column",
               "old_value", "new_value", "action", "batch_id", "note", "edited_at"]
ACTIONS = {"set", "delete_row"}


# ---------------------------------------------------------------- CSV I/O

def parse_csv(text):
    """Parse CSV text into rows of (value, quoted) pairs."""
    rows, row, i, n = [], [], 0, len(text)
    while i < n:
        if text[i] == '"':
            j, buf = i + 1, []
            while True:
                k = text.index('"', j)
                buf.append(text[j:k])
                if k + 1 < n and text[k + 1] == '"':
                    buf.append('"')
                    j = k + 2
                else:
                    i = k + 1
                    break
            row.append(("".join(buf), True))
        else:
            m = re.compile(r"[^,\n]*").match(text, i)
            row.append((m.group(0).rstrip("\r"), False))
            i = m.end()
        if i >= n or text[i] == "\n":
            rows.append(row)
            row = []
            i += 1
        else:  # comma
            i += 1
            if i == n:
                row.append(("", False))
                rows.append(row)
    return rows


class Table:
    """Header, rows of cells (str or None) and which columns R wrote unquoted."""

    def __init__(self, header, rows, bare):
        self.header = header
        self.rows = rows
        self.bare = bare  # set of column names written without quotes (numeric/logical)

    @property
    def index(self):
        return {c: i for i, c in enumerate(self.header)}

    def copy(self):
        return Table(list(self.header), [list(r) for r in self.rows], set(self.bare))


def read_table(path):
    with open(path, encoding="utf-8", newline="") as f:
        parsed = parse_csv(f.read())
    header = [v for v, _ in parsed[0]]
    rows, quoted_seen = [], [False] * len(header)
    for prow in parsed[1:]:
        cells = []
        for j, (v, q) in enumerate(prow):
            if q:
                quoted_seen[j] = True
                cells.append(v)
            else:
                cells.append(v if v != "" else None)
        rows.append(cells)
    bare = {c for c, q in zip(header, quoted_seen) if not q}
    # An all-NA column has no quoted values but is character in R; it only
    # matters if a correction fills it, and then quoting is the safer guess.
    for c in list(bare):
        j = header.index(c)
        if all(r[j] is None for r in rows):
            bare.discard(c)
    return Table(header, rows, bare)


def format_table(table):
    out = [",".join(_quote(c) for c in table.header)]
    for r in table.rows:
        out.append(",".join(
            "" if v is None else (v if c in table.bare else _quote(v))
            for c, v in zip(table.header, r)))
    return "\n".join(out) + "\n"


def _quote(v):
    return '"' + v.replace('"', '""') + '"'


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    # mkstemp creates the file 0600; give the result the permissions a normal write would
    if os.path.exists(path):
        mode = os.stat(path).st_mode & 0o777
    else:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".csv")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


# ---------------------------------------------------------------- log I/O

def read_log(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", newline="") as f:
        return [dict(r) for r in csv.DictReader(f)]


def write_log(path, entries):
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=LOG_COLUMNS, quoting=csv.QUOTE_ALL, lineterminator="\n")
    w.writeheader()
    for e in entries:
        w.writerow({c: e.get(c, "") for c in LOG_COLUMNS})
    write_atomic(path, buf.getvalue())


def new_batch_id(now=None):
    now = now or datetime.now()
    return now.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2)


# ---------------------------------------------------------------- keys / values

def row_key(table, row):
    idx = table.index
    return "\t".join(row[idx[c]] or "" for c in KEY_COLUMNS)


def entry_key(entry):
    return "\t".join(entry.get(c, "") or "" for c in KEY_COLUMNS)


def duplicate_keys(keys):
    """Keys shared by more than one row; corrections can't address those rows."""
    seen, dups = set(), set()
    for k in keys:
        (dups if k in seen else seen).add(k)
    return dups


def normalize_value(value, bare):
    """Turn a user-typed value into the cell R would write. '' means NA."""
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    if not bare:
        return value
    if value.upper() in ("TRUE", "FALSE"):
        return value.upper()
    try:
        x = float(value)
    except ValueError:
        raise ValueError(f"{value!r} is not a number")
    if x.is_integer():
        return str(int(x))
    return repr(x)


def display(v):
    return "" if v is None else v


# ---------------------------------------------------------------- apply

def apply_corrections(baseline, log):
    """Apply log entries in order to a copy of baseline.

    Keys are matched against the baseline (as-scraped) values, so a player
    whose name was corrected is still found by later entries.

    Returns (table, keys, report, touched): keys[i] is the baseline key of
    table.rows[i], report has 'unmatched' and 'stale' entry lists, and
    touched is the set of baseline keys with any correction.
    """
    table = baseline.copy()
    idx = table.index
    keys = [row_key(table, r) for r in table.rows]
    position = {}
    for i, k in enumerate(keys):
        position.setdefault(k, i)  # first match, like R's match()
    dropped, touched = set(), set()
    unmatched, stale = [], []
    for e in log:
        i = position.get(entry_key(e))
        if i is None:
            unmatched.append(e)
            continue
        touched.add(entry_key(e))
        if e["action"] == "delete_row":
            dropped.add(i)
        elif e["action"] == "set":
            col = e["column"]
            if col not in idx:
                unmatched.append(e)
                continue
            current = display(table.rows[i][idx[col]])
            if current != e.get("old_value", ""):
                stale.append({**e, "current": current})
            new = e.get("new_value", "")
            table.rows[i][idx[col]] = None if new == "" else new
    keep = [i for i in range(len(table.rows)) if i not in dropped]
    table.rows = [table.rows[i] for i in keep]
    return table, [keys[i] for i in keep], {"unmatched": unmatched, "stale": stale}, touched
