# Women's College Basketball Coaching History Data

## Overview

This dataset contains coaching history information for women's college basketball programs, compiled from data on current NCAA coaches. The dataset tracks coaches' career progressions across different institutions and roles.

## Data Source

The data was created using information for current NCAA Division I, II, and III women's basketball coaches. Coaching histories were compiled by tracking these coaches' previous positions at various institutions.

## Important Limitations

- **Incomplete histories**: Not all teams have complete coaching histories for all coaches or staff members. The dataset primarily reflects the career paths of coaches who are currently active in NCAA programs.
- **Current coach bias**: Historical coaches who are no longer active in NCAA programs may not be fully represented in this dataset.
- **Staff coverage**: Assistant coaches and other staff members may have less complete historical records than head coaches.

## Data Structure

### Key Fields

- `coach`: Coach name
- `college`: Institution name
- `title`: Original position title
- `team_id`: Unique identifier for the team (see ID system below)
- `start_year`: Year the position began
- `end_year`: Year the position ended (empty for current positions)
- `position_title_standardized`: Standardized version of the position title
- `college_clean`: Standardized institution name
- `category`: Type of institution (e.g., College, NAIA, Community College)
- `team_state`: State where the institution is located
- `conference`: Athletic conference
- `division`: NCAA division (I, II, III) or other classification
- `gender`: Gender identifier

## Team Identification System

The dataset uses two different systems for identifying schools:

### NCAA Schools
- **Identifier**: `team_id` field contains the official NCAA organization ID
- **Consistency**: These IDs are stable and unique across all NCAA Division I, II, and III institutions
- **Use case**: Reliable for joining with other NCAA datasets

### Non-NCAA Schools
- **Identifier**: No unique ID available
- **Identification method**: NAIA schools, community colleges, and other non-NCAA institutions are identified only by their standardized name in the `college_clean` field
- **Limitation**: Joining with other datasets may require careful name matching

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
