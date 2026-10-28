#!/usr/bin/env Rscript
# Repair the 2024-25 roster file after upstream's Dec-2025 raw overhaul.
#
# Diagnosis (see controller's quantification, 2026-10-04): upstream re-scraped
# "rosters_2024-25.csv" from LIVE pages for many schools, so the refreshed
# vintage carries a later season's class years (3,449 of 12,463 shared same-
# player stay rows changed class with zero +1 deltas — only +2/+3 jumps, the
# signature of fetching a future season's page), 1,252 real 2024-25 rows were
# dropped (mostly closed schools), and 892 rows were fabricated by mirroring
# players' 2025-26 records backward (e.g. a 2024-25 "Virginia" row for a
# transfer whose 2024-25 team was elsewhere).
#
# Repair policy (owner-approved): the pre-refresh vintage
# (git f1a5ba0:wbb_rosters_2024_25.csv, the Dec-2024-era scrape) is the
# historical truth wherever it has a value.
#   1. Shared same-player stays (same ncaa_id + normalized name; school-level
#      ncaa_id, so team-label drift rows are the same school): overlay
#      year_clean / raw year / redshirt / total_inches / previous_school_clean
#      from OLD wherever OLD is non-NA; clear NEW's previous_school_clean where
#      OLD had none and the class/redshirt actually changed (it was scraped off
#      a live page).
#   2. NEW-only rows that strong-mirror their 25-26 twin — same school key,
#      identical class, both heights non-NA and equal, hometown equal or both
#      NA — are fabricated and deleted.
#   3. OLD-only rows are restored unchanged, translated to the current schema:
#      player_id dropped, the three HS-standardization columns recomputed by
#      the same join cleaning.Rmd applies, team metadata re-derived from the
#      current teams.csv where unambiguous.
#
# Reproducibility caveats (documented divergences from a fresh knit):
# - restored rows' hs_confidence tests country_clean (season CSVs don't carry
#   the raw `country` column cleaning.Rmd's case_when uses);
# - where country_clean is NA the confidence falls through to mapping/
#   unstandardized rather than NA;
# - restored rows are OLD rows verbatim (translated to the current schema);
#   they have no NEW counterpart, so nothing overlays them.
#
# Run from the repo root, with a full clone (needs `git show` of a historical
# SHA):  Rscript scripts/repair_2024_25_vintage.R

suppressPackageStartupMessages({
  library(readr); library(dplyr); library(tibble); library(stringr)
})

OLD_SHA <- "f1a5ba0"  # last commit carrying the pre-refresh 2024-25 file
NEW_SHA <- "cf3d8d3"  # last commit carrying the broken refresh (pre-repair; the
                      # extended-year re-clean of the upstream Dec-2025 overhaul)
norm <- function(x) gsub("[^a-z]", "", tolower(x))
key_of <- function(ncaa_id, name) paste(ncaa_id, norm(name), sep = "\t")

stopifnot("run from the repo root" = file.exists("wbb_rosters_2024_25.csv") &&
            file.exists("teams.csv") && file.exists("data/high_school_mapping.csv"))

read_sha_file <- function(sha, path) {
  # Both vintages always come from the committed history, so a re-run on the
  # already-repaired repo reproduces the same inputs instead of re-repairing
  # its own output.
  csv <- system2("git", c("show", paste0(sha, ":", path)), stdout = TRUE)
  if (length(csv) <= 1000) stop(sprintf("git show of %s failed", sha))
  f <- tempfile(fileext = ".csv"); writeLines(csv, f, useBytes = TRUE)
  f
}

O  <- read_csv(read_sha_file(OLD_SHA, "wbb_rosters_2024_25.csv"),
               show_col_types = FALSE, locale = locale(encoding = "UTF-8"))
N  <- read_csv(read_sha_file(NEW_SHA, "wbb_rosters_2024_25.csv"),
               show_col_types = FALSE, locale = locale(encoding = "UTF-8"))
S  <- read_csv("wbb_rosters_2025_26.csv", show_col_types = FALSE, locale = locale(encoding = "UTF-8"))
TT <- read_csv("teams.csv", show_col_types = FALSE, na = c("", "NA"), locale = locale(encoding = "UTF-8"))

cat(sprintf("OLD rows=%d cols=%d | NEW rows=%d cols=%d | S26 rows=%d | teams.csv rows=%d\n",
            nrow(O), length(names(O)), nrow(N), length(names(N)), nrow(S), nrow(TT)))

NEW_COLS <- names(N)
OLD_COLS <- names(O)
stopifnot("old/new column sets must differ exactly by player_id + the 3 HS columns" =
            setequal(setdiff(OLD_COLS, NEW_COLS), "player_id") &&
            setequal(setdiff(NEW_COLS, OLD_COLS),
                     c("high_school_standardized", "hs_confidence", "hs_was_standardized")))

# ---- keys and within-file duplicates ----------------------------------------
add_key <- function(df) {
  df$rowid  <- seq_len(nrow(df))
  df$key    <- key_of(df$ncaa_id, df$name)
  df$nnteam <- norm(df$team)
  df
}
O <- add_key(O); N <- add_key(N); S <- add_key(S)

dup_keys <- function(df) df |> group_by(key) |> filter(n() > 1) |> pull(key) |> unique()
keys_dup_old <- dup_keys(O); keys_dup_new <- dup_keys(N); keys_dup_s <- dup_keys(S)
cat(sprintf("within-file duplicate-key rows (kept, but never cross-matched): OLD=%d NEW=%d S26=%d\n",
            sum(O$key %in% keys_dup_old), sum(N$key %in% keys_dup_new),
            sum(S$key %in% keys_dup_s)))
# Duplicate-keyed rows cannot be attributed old<->new one-to-one, so they stay
# out of the overlay and mirror joins -- but they are NOT dropped: NEW's own
# duplicate rows pass through untouched, and OLD's duplicate-keyed rows are
# restored when NEW does not represent the key at all (see step 3).
O_match <- O |> filter(!key %in% keys_dup_old)
N_match <- N |> filter(!key %in% keys_dup_new)
S_match <- S |> filter(!key %in% keys_dup_s)

# ---- 1. shared stays: overlay the OLD vintage -------------------------------
SH <- inner_join(
  O_match |> transmute(o_rowid = rowid, key, o_nteam = nnteam, o_raw = year, o_yr = year_clean,
                 o_rs = as.logical(redshirt), o_h = height_clean, o_hft = height_ft,
                 o_hin = height_in, o_in = total_inches, o_ps = previous_school_clean),
  N_match |> transmute(n_rowid = rowid, key, n_nteam = nnteam, n_raw = year, n_yr = year_clean,
                 n_rs = as.logical(redshirt), n_h = height_clean, n_hft = height_ft,
                 n_hin = height_in, n_in = total_inches, n_ps = previous_school_clean),
  by = "key")
stays <- SH |> mutate(
  o_rs = as.logical(o_rs), n_rs = as.logical(n_rs),
  chg_cls = !is.na(o_yr) & (is.na(n_yr)  | o_yr != n_yr),
  chg_rs  = !is.na(o_rs) & (is.na(n_rs)  | o_rs != n_rs),
  chg_h   = !is.na(o_in) & (is.na(n_in) | is.na(n_h) |
             o_in != n_in | (!is.na(o_h) & o_h != n_h)),
  chg_in  = !is.na(o_in) & (is.na(n_in)  | o_in != n_in),
  cls_ch  = chg_cls | chg_rs)
cat(sprintf("shared keys=%d | same-label stays=%d | label-drift rows (same school)=%d\n",
            nrow(SH), sum(stays$o_nteam == stays$n_nteam), sum(stays$o_nteam != stays$n_nteam)))
cat(sprintf("overlay ledger: year_clean %d | redshirt %d | height %d | total_inches %d | ps_replaced %d\n",
            sum(stays$chg_cls), sum(stays$chg_rs), sum(stays$chg_h), sum(stays$chg_in),
            sum(!is.na(stays$o_ps) & (is.na(stays$n_ps) | stays$o_ps != stays$n_ps))))
stays_clear <- stays |> filter(is.na(o_ps), cls_ch, !is.na(n_ps))
cat(sprintf("                ps_cleared (live-page residue) %d\n", nrow(stays_clear)))

Nv <- N  # working copy; rowid == position
ri <- stays$n_rowid
ovr <- !is.na(stays$o_yr)
Nv$year[ri[ovr]]        <- stays$o_raw[ovr]
Nv$year_clean[ri[ovr]]  <- stays$o_yr[ovr]
ovr <- !is.na(stays$o_rs)
Nv$redshirt[ri[ovr]]    <- stays$o_rs[ovr]
ovr <- !is.na(stays$o_in)
Nv$total_inches[ri[ovr]] <- stays$o_in[ovr]
# The whole height trio must move together with total_inches (review-round
# finding): overlaying only the inches left rows whose height_clean ft/in
# still described the NEW measurement. OLD's parsed inches guarantee its
# string parses too, so any row with o_in carries a self-consistent OLD
# trio; rows whose OLD string never parse (o_in NA) keep NEW's.
ovr <- !is.na(stays$o_in)
Nv$height_clean[ri[ovr]] <- stays$o_h[ovr]
Nv$height_ft[ri[ovr]]    <- stays$o_hft[ovr]
Nv$height_in[ri[ovr]]    <- stays$o_hin[ovr]
ovr <- !is.na(stays$o_ps)
Nv$previous_school_clean[ri[ovr]] <- stays$o_ps[ovr]
Nv$previous_school_clean[stays_clear$n_rowid] <- NA

# ---- 2. drop strong-mirror NEW-only rows ------------------------------------
new_only <- Nv |> filter(!key %in% SH$key)   # includes NEW's duplicate-keyed rows
mt <- new_only |>
  inner_join(S_match |> transmute(key, s_yr = year_clean, s_in = total_inches,
                            s_hc = hometown_clean, s_team = team), by = "key") |>
  mutate(mirror =
           !is.na(year_clean) & !is.na(s_yr) & year_clean == s_yr &
           !is.na(total_inches) & !is.na(s_in) & total_inches == s_in &
           ((is.na(hometown_clean) & is.na(s_hc)) |
            (!is.na(hometown_clean) & !is.na(s_hc) & hometown_clean == s_hc)))
dropped <- mt |> filter(mirror) |> distinct(rowid, .keep_all = TRUE)
cat(sprintf("NEW-only keys=%d | with S26 twin=%d | strong mirrors dropped=%d (%d label-identical)\n",
            nrow(new_only), nrow(mt), nrow(dropped),
            sum(dropped$nnteam == norm(dropped$s_team))))
Nv <- Nv |> filter(!rowid %in% dropped$rowid)
cat(sprintf("NEW duplicate-key rows passed through untouched: %d (of %d)\n",
            nrow(Nv |> filter(key %in% keys_dup_new, !rowid %in% dropped$rowid)),
            sum(N$key %in% keys_dup_new)))

# ---- 3. restore OLD-only rows ------------------------------------------------
# OLD rows that NEW does not represent at all (any representation, duplicated
# or not). OLD duplicate-keyed rows restore too when NEW has none of them,
# collapsed to one copy where the two are identical on (team, name, jersey).
restored <- O |> filter(!key %in% SH$key, !key %in% unique(N_match$key))
old_dup_restored <- restored |> filter(key %in% keys_dup_old)
restored <- bind_rows(
  restored |> filter(!key %in% keys_dup_old),
  old_dup_restored |> distinct(ncaa_id, team, name, jersey, .keep_all = TRUE))
cat(sprintf("OLD duplicate-key rows restored: %d -> %d (exact copies collapsed)\n",
            nrow(old_dup_restored),
            nrow(old_dup_restored |> distinct(ncaa_id, team, name, jersey))))
cat(sprintf("OLD-only keys restored=%d\n", nrow(restored)))
HS <- read_csv("data/high_school_mapping.csv", show_col_types = FALSE,
               locale = locale(encoding = "UTF-8")) |>
  select(high_school_original, high_school_standardized, confidence, source) |>
  arrange(confidence != "high_manual") |>          # prefer the manually reviewed row
  distinct(high_school_original, .keep_all = TRUE)
restored <- restored |>
  select(all_of(setdiff(NEW_COLS, c("high_school_standardized", "hs_confidence",
                                    "hs_was_standardized")))) |>
  left_join(HS, by = c("hs_clean" = "high_school_original"), relationship = "many-to-one") |>
  mutate(
    high_school_standardized = coalesce(high_school_standardized, hs_clean),
    hs_confidence = case_when(
      !is.na(confidence) ~ confidence,
      !is.na(country_clean) & country_clean != "USA" ~ "international",
      is.na(hs_clean) ~ "missing",
      TRUE ~ "unstandardized"),
    hs_was_standardized = hs_clean != high_school_standardized & !is.na(high_school_standardized)) |>
  select(-confidence, -source)
cat(sprintf("restored rows with NA country_clean (int'l fallback skipped): %d\n",
            sum(!is.na(restored$hs_clean) & is.na(restored$country_clean))))
tt_uniq <- TT |> distinct(ncaa_id, team_state, conference, division) |>
  group_by(ncaa_id) |> filter(n() == 1) |> ungroup() |>
  transmute(ncaa_id, ts_n = team_state, cf_n = conference, dv_n = division)
meta_ambig <- restored |> distinct(ncaa_id) |> anti_join(tt_uniq, by = "ncaa_id")
restored <- restored |>
  left_join(tt_uniq, by = "ncaa_id") |>
  mutate(team_state = coalesce(ts_n, team_state),
         conference = coalesce(cf_n, conference),
         division   = coalesce(dv_n, division)) |>
  select(-ts_n, -cf_n, -dv_n)
stopifnot("every restored ncaa_id must exist in teams.csv" =
            nrow(restored |> distinct(ncaa_id) |> anti_join(TT |> distinct(ncaa_id), by = "ncaa_id")) == 0,
          "restored rows carry season 2024-25" = all(restored$season == "2024-25"))
cat(sprintf("restored ncaa_ids with ambiguous teams.csv metadata (kept OLD values): %d\n",
            nrow(meta_ambig)))

# ---- assemble + guards --------------------------------------------------------
final <- bind_rows(Nv |> select(-rowid, -key, -nnteam), restored) |> select(all_of(NEW_COLS))
jkey  <- paste(final$ncaa_id, final$team, final$name,
               coalesce(as.character(final$jersey), ""), sep = "\t")
stopifnot("final row count" = nrow(final) == nrow(N) - nrow(dropped) + nrow(restored),
          "column set/order unchanged" = identical(names(final), NEW_COLS),
          "no duplicate (ncaa_id, team, name, jersey) rows" = !any(duplicated(jkey)),
          "all rows are season 2024-25" = all(final$season == "2024-25"),
          "every team ncaa_id present in teams.csv" =
            nrow(final |> distinct(ncaa_id) |> anti_join(TT |> distinct(ncaa_id), by = "ncaa_id")) == 0)

# every key UNIQUE in both vintages must carry OLD's class/redshirt/height in
# the final file. The guarantee covers uniquely-matched keys only: keys
# duplicated in either vintage are unattributable, so NEW's own rows pass
# through (see the duplicate-key section) and stay out of these joins.
chk <- final |> transmute(key = key_of(ncaa_id, name), f_yr = year_clean,
                          f_rs = as.logical(redshirt)) |>
  filter(!key %in% keys_dup_new) |>
  inner_join(O_match |> transmute(key, o_yr = year_clean, o_rs = as.logical(redshirt)), by = "key") |>
  filter(!is.na(o_yr))
stopifnot("overlaid classes must match the old vintage" = all(chk$f_yr == chk$o_yr))
chk2 <- final |> transmute(key = key_of(ncaa_id, name), f_rs = as.logical(redshirt)) |>
  filter(!key %in% keys_dup_new) |>
  inner_join(O_match |> transmute(key, o_rs = as.logical(redshirt)), by = "key") |>
  filter(!is.na(o_rs))
stopifnot("overlaid redshirt flags must match the old vintage" = all(chk2$f_rs == chk2$o_rs))

# every uniquely-matched key with an OLD height value must carry that value in
# the final file, and the string must agree with total_inches everywhere the
# string parses
chk3 <- final |>
  transmute(key = key_of(ncaa_id, name), f_h = height_clean, f_tot = total_inches) |>
  filter(!key %in% keys_dup_new) |>
  inner_join(O_match |> transmute(key, o_h = height_clean, o_tot = total_inches), by = "key")
tot3 <- chk3 |> filter(!is.na(o_tot), !is.na(f_tot))
# The string overlay's domain is the same as the inches overlay's: rows whose
# OLD total_inches parsed. Where OLD's string never parsed (o_tot NA -- 3 keys,
# e.g. unparseable vintage strings), NEW's height stands by design, so those
# rows stay out of this comparison; the global parse-consistency check below
# still covers whatever NEW kept.
str3 <- chk3 |> filter(!is.na(o_h), !is.na(f_h), !is.na(o_tot))
hm <- str_match(final$height_clean, "^([0-9]+)['-]\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(?:''|\")?$")
stopifnot("overlaid total_inches must match the old vintage" = all(tot3$f_tot == tot3$o_tot),
          "overlaid height strings must match the old vintage" = all(str3$f_h == str3$o_h),
          "height_clean must agree with total_inches wherever the string parses" =
            sum(!is.na(hm[, 2]) & !is.na(final$total_inches) &
                  as.numeric(hm[, 2]) * 12 + as.numeric(hm[, 3]) != final$total_inches) == 0)

# Duplicate-keyed OLD rows are unattributable, so where NEW does represent the
# key, final carries NEW's row -- but NEW's scraped class must agree with at
# least one OLD copy (the rows are true duplicates of the same player; a NEW
# class matching neither copy would mean the live-page drift hit a key the
# overlay can't reach). OLD's Lewis rows carry 3 such self-contradicting pairs
# (e.g. Tara Gugliuzza {Junior, Senior}); NEW's representation always agreed
# with one copy, and this pins that agreement.
dupO_in_N <- keys_dup_old[keys_dup_old %in% N_match$key]
chkD <- final |> transmute(key = key_of(ncaa_id, name), f_yr = year_clean) |>
  filter(key %in% dupO_in_N, !is.na(f_yr)) |>
  inner_join(
    O |> filter(key %in% dupO_in_N) |> transmute(key, o_yr = year_clean), by = "key") |>
  filter(!is.na(o_yr)) |>
  group_by(key, f_yr) |> summarise(hit = any(f_yr == o_yr), .groups = "drop")
stopifnot("NEW's representation of duplicate-keyed OLD rows must match one OLD copy's class" = all(chkD$hit),
          "every duplicate-OLD key NEW represents must be guarded" = setequal(unique(chkD$key), dupO_in_N))

# ---- post-repair live-season mirror rate (should fall to the honest ~6-7%) -----
both <- final |> transmute(key = key_of(ncaa_id, name), nteam = norm(team), f_yr = year_clean) |>
  inner_join(S |> transmute(key, s_nteam = nnteam, s_yr = year_clean), by = "key") |>
  filter(!is.na(f_yr), !is.na(s_yr), nteam == s_nteam)
cat(sprintf("post-repair shared-stay class==25-26 rate: %.1f%% (honest-era control ~6.5%%)\n",
            100 * mean(both$f_yr == both$s_yr)))

cat(sprintf("\nLEDGER: rows=%d teams=%d | deleted mirrors=%d | restored=%d | overlay cells: y %d rs %d h %d in %d ps %d + %d cleared\n",
            nrow(final), n_distinct(final$ncaa_id), nrow(dropped), nrow(restored),
            sum(stays$chg_cls), sum(stays$chg_rs), sum(stays$chg_h), sum(stays$chg_in),
            sum(!is.na(stays$o_ps) & (is.na(stays$n_ps) | stays$o_ps != stays$n_ps)), nrow(stays_clear)))

# ---- teams.csv: collapse duplicate (ncaa_id, team) rows ------------------------
# Edited in place (first row of each pair becomes the union of non-NA fields,
# second row deleted) so every untouched line stays byte-identical.
lines_before <- readLines("teams.csv", warn = FALSE)
TB <- read_csv("teams.csv", show_col_types = FALSE, na = c("", "NA"), locale = locale(encoding = "UTF-8"))
TB$rowid <- seq_len(nrow(TB))
tb_dups <- TB |> count(ncaa_id, team) |> filter(n > 1)
# Pins the 4 audited duplicate pairs from the 2026-10-04 run; 0 is the normal
# value when teams.csv is already collapsed. Any other count fails loudly.
stopifnot("duplicate (ncaa_id, team) groups must be 4 pairs (or none: already collapsed)" =
            nrow(tb_dups) %in% c(0, 4) && all(tb_dups$n == 2))
if (nrow(tb_dups) == 0) {
  cat("teams.csv: no duplicate (ncaa_id, team) rows; leaving it untouched\n")
} else {
  # The edit must not disturb any other byte: reproduce this script's own
  # serialization (readr's write_csv, then CRLF with no trailing newline) and
  # compare against the file raw-byte by raw-byte -- readLines alone is blind
  # to the trailing-newline difference (review-round finding). Checked only on
  # the editing path: a no-op run leaves the committed file alone entirely.
  rt <- tempfile(fileext = ".csv"); write_csv(TB |> select(-rowid), rt, na = "")
  stopifnot("teams.csv must round-trip byte-identically before we edit it" =
              identical(charToRaw(paste0(readLines(rt, warn = FALSE), collapse = "\r\n")),
                        readBin("teams.csv", "raw", n = file.size("teams.csv"))))
  cols <- setdiff(names(TB), "rowid")
  drop_rowids <- integer(0)
  for (i in seq_len(nrow(tb_dups))) {
    g <- TB |> filter(ncaa_id == tb_dups$ncaa_id[i], team == tb_dups$team[i])
    stopifnot("dup rows must agree on team_state/conference/division" =
                identical(g$team_state[1], g$team_state[2]) &&
                identical(g$conference[1], g$conference[2]) &&
                identical(g$division[1], g$division[2]))
    for (cn in cols) {
      v <- g[[cn]]; idx <- which(!is.na(v))
      if (length(idx)) TB[[cn]][g$rowid[1]] <- v[idx[1]]
    }
    drop_rowids <- c(drop_rowids, g$rowid[2])
    cat(sprintf("collapsing %d %s (kept row %d, dropped row %d)\n",
                g$ncaa_id[1], g$team[1], g$rowid[1], g$rowid[2]))
  }
  TB <- TB |> filter(!rowid %in% drop_rowids) |> select(-rowid)
  tb_after <- tempfile(fileext = ".csv"); write_csv(TB, tb_after, na = "")
  # teams.csv is CRLF with no trailing newline — reproduce that convention exactly
  cat(paste0(readLines(tb_after), collapse = "\r\n"), file = "teams.csv", sep = "")
  cat(sprintf("teams.csv: %d -> %d rows (duplicates collapsed)\n", length(lines_before) - 1, nrow(TB)))
}

# ---- outputs -------------------------------------------------------------------
stays <- stays |> mutate(
  ps_rep = !is.na(o_ps) & (is.na(n_ps) | o_ps != n_ps),
  ps_clr = is.na(o_ps) & cls_ch & !is.na(n_ps))
write_csv(stays |> filter(chg_cls | chg_rs | chg_in | ps_rep | ps_clr) |>
            transmute(key, o_team = o_nteam, n_yr, o_yr, n_raw, o_raw, n_rs, o_rs, n_in, o_in,
                      n_ps, o_ps, ps_rep, ps_clr),
          "/tmp/repair_overlay_rows.csv")
write_csv(dropped |> transmute(rowid, nnteam, name, s_team, year_clean, total_inches,
                               hometown = hometown_clean, s_hc),
          "/tmp/repair_dropped_mirrors.csv")
write_csv(restored, "/tmp/repair_restored_rows.csv")
write_csv(final, "wbb_rosters_2024_25.csv", quote = "all", na = "")
cat("wrote wbb_rosters_2024_25.csv and deduped teams.csv\n")