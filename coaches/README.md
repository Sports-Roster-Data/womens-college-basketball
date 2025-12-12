# Women's College Basketball Coaching History Data

## Overview

This dataset contains coaching history information for women's college basketball programs, compiled from data on current NCAA coaches. The dataset tracks coaches' career progressions across different institutions and roles. This dataset was compiled and edited by students in JOUR479X, Sports Data Analysis and Visualization, a journalism class at the University of Maryland taught by Derek Willis. The following students contributed to the project:

* Andrew Breza
* Nyla Cherry
* Matthew Cohen
* Trevor Gomes
* Michael Howes
* Sam Jane
* Max Schaeffer
* Dylan Schmidt
* Tahlia Williams

## Data Source

The data was created using information for current NCAA Division I, II, and III women's basketball coaches as recorded on official team sites. Coaching histories were compiled using the official biographies from those sites ([an example](https://umterps.com/sports/womens-basketball/roster/coaches/brenda-frese/2642)). The class used Claude Haiku 4.5, a large language model, to parse information from coaching biographies into structured data, and students provided research assistance.

## Basic Analysis

Included in this repository is a [RMarkdown notebook](coaches.Rmd) that explores the data using R.

## Important Limitations

- **Incomplete histories**: Not all teams have complete coaching histories for all coaches or staff members. The dataset reflects the career paths of coaches who are currently active in NCAA programs.
- **Current coach bias**: Historical coaches who are no longer active in NCAA programs are represented in this dataset.
- **Staff coverage**: Assistant coaches and other staff members often may have less complete historical records than head coaches, or are missing work histories.

## Data Structure

### Key Fields

- `coach`: Coach name
- `college`: Institution name
- `title`: Original position title
- `team_id`: Unique identifier for the team (NCAA teams only)
- `start_year`: Year the position began
- `end_year`: Year the position ended (empty for current positions)
- `position_title_standardized`: Standardized version of the position title
- `college_clean`: Standardized institution name
- `category`: Type of organization (e.g., College, Professional, Community College)
- `team_state`: State where the college is located
- `conference`: Athletic conference ((NCAA teams only))
- `division`: NCAA division (I, II, III) classification
- `gender`: Gender identifier (derived from pronouns used in bio; not available for all coaches)

## Usage Notes

When working with this data:

1. Use `team_id` to join NCAA schools with other datasets
2. For non-NCAA schools, use `college_clean` for matching, but be aware of potential naming variations
3. Empty `end_year` values indicate current positions
4. Check the `category` field to distinguish between NCAA and non-NCAA institutions
5. The `position_title_standardized` field provides consistent role classifications across varying title formats

## Data Quality

This is a best-effort compilation based on publicly available information. Users should be aware that:
- Coaching histories may be incomplete for some individuals
- Start and end dates may have some uncertainty
- Position titles and classifications represent interpretations of source data
