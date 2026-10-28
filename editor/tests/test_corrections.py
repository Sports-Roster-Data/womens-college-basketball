import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import corrections as corr  # noqa: E402
import app as editor  # noqa: E402

ROSTER = (
    '"team","ncaa_id","season","jersey","name","hometown","total_inches","redshirt","note"\n'
    '"Akron",5,"2026-27",1,"Ann Lee","Ohio",70,FALSE,""\n'
    '"Akron",5,"2026-27",2,"Bea Cole","Kent",,TRUE,"x ""q"" y"\n'
    '"Akron",5,"2026-27",,"Cat Diaz",,72,FALSE,\n'
    '"Ball State",7,"2026-27",1,"Ann Lee","Muncie",68,FALSE,\n'
)


def key(ncaa_id, team, name, jersey):
    return "\t".join([str(ncaa_id), team, name, jersey])


def entry(k, action="set", column="", old="", new="", batch="b1"):
    ncaa_id, team, name, jersey = k.split("\t")
    return {"season": "2026-27", "ncaa_id": ncaa_id, "team": team, "name": name,
            "jersey": jersey, "column": column, "old_value": old, "new_value": new,
            "action": action, "batch_id": batch, "note": "n", "edited_at": "t"}


@pytest.fixture
def baseline(tmp_path):
    p = tmp_path / "r.csv"
    p.write_text(ROSTER)
    return corr.read_table(str(p))


def test_round_trip_is_byte_identical(baseline):
    assert corr.format_table(baseline) == ROSTER
    assert baseline.bare == {"ncaa_id", "jersey", "total_inches", "redshirt"}


def test_single_set(baseline):
    k = key(5, "Akron", "Ann Lee", "1")
    t, keys, report, touched = corr.apply_corrections(baseline, [entry(k, column="hometown", old="Ohio", new="Akron, OH")])
    assert t.rows[0][5] == "Akron, OH"
    assert report == {"unmatched": [], "stale": []}
    assert touched == {k}
    assert '"Akron, OH"' in corr.format_table(t)


def test_numeric_set_stays_unquoted_and_na(baseline):
    k = key(5, "Akron", "Bea Cole", "2")
    t, *_ = corr.apply_corrections(baseline, [entry(k, column="total_inches", old="", new="71")])
    assert ',"Kent",71,TRUE,' in corr.format_table(t)
    t, *_ = corr.apply_corrections(baseline, [entry(key(5, "Akron", "Ann Lee", "1"), column="total_inches", old="70", new="")])
    assert '"Ohio",,FALSE' in corr.format_table(t)


def test_delete(baseline):
    k = key(5, "Akron", "Bea Cole", "2")
    t, keys, report, _ = corr.apply_corrections(baseline, [entry(k, action="delete_row")])
    assert len(t.rows) == 3 and k not in keys
    assert report["unmatched"] == []


def test_bulk_batch(baseline):
    ks = [key(5, "Akron", "Ann Lee", "1"), key(5, "Akron", "Bea Cole", "2"), key(7, "Ball State", "Ann Lee", "1")]
    olds = ["Ohio", "Kent", "Muncie"]
    log = [entry(k, column="hometown", old=o, new="X") for k, o in zip(ks, olds)]
    t, *_ = corr.apply_corrections(baseline, log)
    assert [r[5] for r in t.rows] == ["X", "X", None, "X"]


def test_na_jersey_key(baseline):
    k = key(5, "Akron", "Cat Diaz", "")
    t, keys, report, _ = corr.apply_corrections(baseline, [entry(k, column="hometown", old="", new="Toledo")])
    assert t.rows[2][5] == "Toledo" and report["unmatched"] == []


def test_rename_then_edit_uses_original_key(baseline):
    k = key(5, "Akron", "Ann Lee", "1")
    log = [entry(k, column="name", old="Ann Lee", new="Anne Lee"),
           entry(k, column="hometown", old="Ohio", new="Akron", batch="b2")]
    t, keys, report, _ = corr.apply_corrections(baseline, log)
    assert t.rows[0][4] == "Anne Lee" and t.rows[0][5] == "Akron"
    assert keys[0] == k and report == {"unmatched": [], "stale": []}


def test_stale_and_unmatched(baseline):
    log = [entry(key(5, "Akron", "Ann Lee", "1"), column="hometown", old="Columbus", new="Akron"),
           entry(key(5, "Akron", "Nobody", "9"), column="hometown", old="", new="Y")]
    t, _, report, _ = corr.apply_corrections(baseline, log)
    assert [e["current"] for e in report["stale"]] == ["Ohio"]
    assert [e["name"] for e in report["unmatched"]] == ["Nobody"]
    assert t.rows[0][5] == "Akron"  # stale corrections still apply


def test_normalize_value():
    assert corr.normalize_value("70.0", True) == "70"
    assert corr.normalize_value("5.5", True) == "5.5"
    assert corr.normalize_value("true", True) == "TRUE"
    assert corr.normalize_value("  ", False) is None
    with pytest.raises(ValueError):
        corr.normalize_value("tall", True)


# ---------------------------------------------------------------- app

@pytest.fixture
def client(tmp_path):
    (tmp_path / "wbb_rosters_2026_27.csv").write_text(ROSTER)
    editor.app.config.update(ROOT=str(tmp_path), DEFAULT_SEASON="2026-27", TESTING=True)
    return editor.app.test_client(), editor.Paths("2026-27", root=str(tmp_path))


def post(c, rows, note="fix", season=""):
    return c.post(f"/api/corrections?season={season}", data=json.dumps({"note": note, "rows": rows}),
                  content_type="application/json")


def test_app_save_undo_and_idempotent(client):
    c, paths = client
    k = key(5, "Akron", "Ann Lee", "1")
    r = post(c, [{"_key": k, "column": "hometown", "new_value": "Akron, OH"}])
    assert r.status_code == 200
    assert '"Akron, OH"' in open(paths.roster).read()
    r = post(c, [{"_key": key(5, "Akron", "Bea Cole", "2"), "action": "delete_row"}])
    batch = r.get_json()["batch_id"]
    assert "Bea Cole" not in open(paths.roster).read()
    rows = c.get("/api/rows").get_json()
    assert len(rows["rows"]) == 3 and rows["rows"][0]["_corrected"]
    assert len(c.get("/api/batches").get_json()) == 2

    assert c.delete(f"/api/batches/{batch}").status_code == 200
    assert "Bea Cole" in open(paths.roster).read()

    # Rebuilding twice from baseline + log gives the same bytes
    before = open(paths.roster).read()
    editor.rebuild(paths)
    assert open(paths.roster).read() == before


def test_app_validation(client):
    c, _ = client
    k = key(5, "Akron", "Ann Lee", "1")
    assert post(c, [{"_key": k, "column": "hometown", "new_value": "x"}], note="").status_code == 400
    assert post(c, [{"_key": k, "column": "team", "new_value": "x"}]).status_code == 400
    assert post(c, [{"_key": k, "column": "nope", "new_value": "x"}]).status_code == 400
    assert post(c, [{"_key": k, "column": "total_inches", "new_value": "tall"}]).status_code == 400
    assert post(c, [{"_key": k, "column": "hometown", "new_value": "Ohio"}]).status_code == 400  # unchanged


def test_first_match_wins_like_r(baseline):
    dup = baseline.copy()
    dup.rows.append(list(dup.rows[0]))
    dup.rows[-1][5] = "Second copy"
    k = key(5, "Akron", "Ann Lee", "1")
    t, keys, _, _ = corr.apply_corrections(dup, [entry(k, column="hometown", old="Ohio", new="X")])
    assert t.rows[0][5] == "X" and t.rows[-1][5] == "Second copy"
    assert corr.duplicate_keys(keys) == {k}


def test_app_seasons_and_season_param(client, tmp_path):
    c, paths = client
    older = ROSTER.replace("2026-27", "2025-26")
    (tmp_path / "wbb_rosters_2025_26.csv").write_text(older)
    (tmp_path / "wbb_rosters_combined.csv").write_text(ROSTER)
    assert c.get("/api/seasons").get_json() == {"seasons": ["2026-27", "2025-26"], "default": "2026-27"}
    assert c.get("/api/rows").get_json()["season"] == "2026-27"
    assert c.get("/api/rows?season=2025-26").get_json()["season"] == "2025-26"
    assert c.get("/api/rows?season=1999-00").status_code == 404

    # Browsing creates nothing; the first save bootstraps the baseline for that season only
    assert not (tmp_path / "corrections").exists()
    r = post(c, [{"_key": key(5, "Akron", "Ann Lee", "1"), "column": "hometown", "new_value": "Akron"}], season="2025-26")
    assert r.status_code == 200
    assert (tmp_path / "corrections" / "baseline_2025_26.csv").read_text() == older
    assert not (tmp_path / "corrections" / "baseline_2026_27.csv").exists()
    assert '"Akron",5,"2025-26",1,"Ann Lee","Akron"' in (tmp_path / "wbb_rosters_2025_26.csv").read_text()
    assert (tmp_path / "wbb_rosters_2026_27.csv").read_text() == ROSTER
    assert len(c.get("/api/batches?season=2025-26").get_json()) == 1
    assert c.get("/api/batches").get_json() == []


def test_app_rejects_duplicate_key_rows(client, tmp_path):
    c, paths = client
    first_line = ROSTER.splitlines()[1]
    (tmp_path / "wbb_rosters_2026_27.csv").write_text(ROSTER + first_line + "\n")
    rows = c.get("/api/rows").get_json()["rows"]
    assert [r["_ambiguous"] for r in rows] == [True, False, False, False, True]
    assert len({r["_row"] for r in rows}) == 5
    r = post(c, [{"_key": key(5, "Akron", "Ann Lee", "1"), "column": "hometown", "new_value": "X"}])
    assert r.status_code == 400 and "more than once" in r.get_json()["error"]


def test_write_atomic_keeps_normal_permissions(tmp_path):
    new = tmp_path / "new.csv"
    corr.write_atomic(str(new), "a\n")
    umask = os.umask(0)
    os.umask(umask)
    assert new.stat().st_mode & 0o777 == 0o666 & ~umask
    existing = tmp_path / "existing.csv"
    existing.write_text("x\n")
    existing.chmod(0o640)
    corr.write_atomic(str(existing), "y\n")
    assert existing.stat().st_mode & 0o777 == 0o640
