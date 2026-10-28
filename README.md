# Womens College Basketball
Roster data for women's college basketball teams

The `wbb_rosters_2023_24.csv` file in this repository contains information on more than 13,800 NCAA women's basketball players from more than 900 teams for the 2023-24 season. It is current as of Tuesday, November 14, 2023, although rosters do change frequently.

This data is a project of the JOUR479X class, Sports Data Analysis & Visualization, at the Philip Merrill College of Journalism at the University of Maryland. Please credit the Sports Roster Data project at the University of Maryland.

The following students have contributed to this project:

* Ben Baruch
* Michael Charles
* Shane Connuck
* Ian Decker
* Jetson Ku
* Tanner Malinowski
* Varun Shankar
* Rina Torchinsky
* Dylan Manfre

This project was supervised and edited by Derek Willis, lecturer in data and computational journalism.

The original roster information is drawn from team websites, mostly obtained via [scrapers written in Python](https://github.com/dwillis/wbb/blob/master/ncaa/rosters.py). That information has been augmented by individual research and editing. For example, a transfer player's high school may not be noted on her current team, but it could be found on her previous team's roster. Team information comes from [the NCAA](https://stats.ncaa.org/rankings?academic_year=2023&sport_code=WBB).

The roster data in this repository has been cleaned and standardized by student contributors using R; a description of that process and the code is available in [this RMarkdown Notebook](cleaning.Rmd). Some basic exploratory analysis can be seen in [this notebook](exploration.Rmd).

The specific information cleaned and parsed includes the following:

* Position (also standardized)
* Height (standardized and converted to total inches to make comparisons possible)
* Year (also standardized; because this information could refer to either academic or athletic eligibility, it may not be reflective of one of those - and COVID eligibility added more complexity)
* Hometown (parsed using the [postmastr](https://slu-opengis.github.io/postmastr/) package, then separated into hometown, state and country-specific fields. For foreign countries, we started with the list of FIBA nations and added others, then standardized the results)
* Previous School (probably the least consistent column in this data because of the way it is presented in the original data; we did make an attempt to move high schools listed in this column to the high school field)

Recent additions to standardization (November 2025):

* **High School** - Partially standardized using automated duplicate resolution and manual curation. See [HIGH_SCHOOL_STANDARDIZATION.md](HIGH_SCHOOL_STANDARDIZATION.md) for details. Coverage: ~44% of US player-seasons, with ongoing work to expand via NCES data matching.

We have *not* completely standardized the following data:

* Hometown (parsed but not normalized)
* Previous School (inconsistent formatting remains)

## Correcting data

Individual fixes (one player's hometown, a bulk fix across filtered rows, deleting a bad row) are made in a small browser editor rather than by editing the season CSV directly:

```bash
python3 -m venv editor/.venv && editor/.venv/bin/pip install -r editor/requirements.txt
editor/.venv/bin/python editor/app.py
```

Then open http://127.0.0.1:5050 and pick a season from the menu (it opens on 2026-27; `--season` changes that). Every save is recorded with a note in `corrections/corrections_<season>.csv` and the season CSV is rewritten immediately. `cleaning.Rmd` re-applies the same corrections on every knit, so they survive new scrapes; its **Manual Corrections** output lists any corrections whose player can no longer be found or whose scraped value has changed since the edit. Each batch can be undone from the editor's side panel.

The editor rebuilds the season CSV from `corrections/baseline_<season>.csv`, the uncorrected output that `cleaning.Rmd` writes on each knit (not committed). A season that has never been corrected gets its baseline copied from the season CSV on the first save; on a fresh checkout, knit `cleaning.Rmd` before editing a season that already has corrections. Older season files contain a few rows that repeat the same team, name and jersey; the editor greys these out and won't correct them, since a correction couldn't tell the copies apart.

We welcome comments, corrections and questions. Please use [this repository's Issues](https://github.com/Sports-Roster-Data/womens-college-basketball/issues) to let us know about any errors or omissions, or submit a pull request with any changes.
