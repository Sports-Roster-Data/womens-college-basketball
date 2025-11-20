# High School Standardization

## Overview

This document describes the high school name standardization process for the women's college basketball roster dataset. The goal is to create canonical, consistent names for high schools while being conservative in accepting standardizations.

## Current Status

- **Total unique high schools**: 17,679 (across all roster years)
- **After normalization**: 12,602 canonical names
- **Duplicates resolved**: ~5,000 naming variations
- **Coverage**: 44.2% of US player-seasons mapped (as of initial implementation)
- **International schools**: 1,968 (preserved in original format)

## Methodology

### 1. Normalization Strategy

High school names are normalized using conservative rules:

- **Case standardization**: Convert to uppercase for matching
- **Suffix standardization**: Remove variations of "HS", "H.S.", "High School"
- **Punctuation**: Standardize "St." to "Saint", remove periods and commas
- **Whitespace**: Collapse multiple spaces
- **Parenthetical notes**: Remove for matching (e.g., "(Saint Rose)") but preserve in metadata

### 2. Canonical Name Selection

When multiple variations exist, the canonical name is selected by:

1. **Frequency**: Most common version (by player count)
2. **Suffix preference**: "High School" > "HS" > "H.S."
3. **Clarity**: Fewer periods and special characters preferred
4. **Alphabetical**: If still tied, first alphabetically

### 3. Confidence Levels

Each mapping has a confidence level:

- **`high_auto`**: Automatically resolved duplicates (same school, different formatting)
- **`high_manual`**: Manually curated (prep schools, well-known programs)
- **`medium_nces`**: Matched against NCES data (when available)
- **`low_fuzzy`**: Fuzzy string matching (requires review)
- **`international`**: International schools (preserved as-is)
- **`unstandardized`**: No mapping available yet

### 4. Data Sources

#### Current Sources

1. **Internal deduplication**: 5,807 mappings from suffix variations
2. **Manual curation**: 25 prep schools and basketball academies

#### Future Sources (Not Yet Implemented)

1. **NCES Common Core of Data (CCD)**: ~100,000 US public schools
   - Provides canonical names, addresses, NCES IDs
   - Download from: https://nces.ed.gov/ccd/files.asp
   - API access: https://educationdata.urban.org/api/v1/schools/ccd/directory/

2. **NCES Private School Universe Survey (PSS)**: Private school data
   - For schools not in CCD (religious schools, independent schools)

## Files

### Generated Data Files

| File | Description | Records |
|------|-------------|---------|
| `data/high_schools_unique.csv` | All unique high schools from roster data | 17,679 |
| `data/high_schools_potential_duplicates.csv` | Schools with same normalized name | 5,807 |
| `data/high_school_mapping.csv` | **Main mapping file** (original → standardized) | 5,832 |
| `data/high_schools_unmapped.csv` | US schools not yet standardized | 9,889 |
| `data/high_schools_prep_academies.csv` | Prep schools for manual curation | 1,122 |
| `data/high_schools_international.csv` | International schools | 1,968 |
| `data/high_schools_us_for_matching.csv` | US public schools ready for NCES matching | 13,466 |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/normalize_high_schools.py` | Extract and normalize all high schools from roster CSVs |
| `scripts/build_hs_mapping.py` | Build standardization mapping from duplicates and manual lists |
| `scripts/apply_hs_standardization.R` | Apply mapping to roster data (R function) |
| `scripts/download_nces_data.py` | Download NCES CCD data (API currently blocked) |

## Usage

### Running the Standardization Pipeline

```bash
# 1. Extract and analyze high schools
python3 scripts/normalize_high_schools.py

# 2. Build standardization mapping
python3 scripts/build_hs_mapping.py

# 3. Review generated files in data/
#    - Check data/high_school_mapping.csv for accuracy
#    - Review data/high_schools_unmapped.csv for manual additions

# 4. Apply standardization in R (from cleaning.Rmd)
```

### Integrating into cleaning.Rmd

Add to `cleaning.Rmd` after existing high school cleaning logic:

```r
# Load standardization function
source("scripts/apply_hs_standardization.R")

# Apply standardization
wbb_rosters <- apply_hs_standardization(wbb_rosters)
```

This adds three new columns:
- `high_school_standardized`: Canonical name
- `hs_confidence`: Confidence level of standardization
- `hs_was_standardized`: Boolean flag indicating if name changed

### Adding Manual Mappings

To add manual mappings for schools not yet covered:

1. Open `data/high_school_mapping.csv`
2. Add rows with format:
   ```csv
   high_school_original,high_school_standardized,state,confidence,source,nces_id,player_count,canonical_player_count,city,notes
   "My High School","My High School",CA,high_manual,manual_addition,,15,15,Los Angeles,Verified via school website
   ```
3. Re-run `apply_hs_standardization.R`

## Known Issues and Limitations

### Current Limitations

1. **Common school names are ambiguous**: Schools named "Central", "Liberty", "Franklin" appear in many states
   - **Solution**: Need city information or NCES data to disambiguate
   - **Workaround**: Currently unmapped unless they appear with different suffixes

2. **NCES API access blocked**: Urban Institute API returns 403 errors
   - **Solution**: Download CCD data files manually from NCES website
   - **Alternative**: Use state-specific APIs if available

3. **International schools not standardized**: Preserved in original format
   - **Rationale**: No canonical international school database exists
   - **Future**: Could use Wikipedia or FIBA data for major programs

4. **Name changes over time**: Schools that merged, closed, or renamed
   - **Current approach**: Accept variations; note in metadata
   - **Improvement**: Track historical names with year ranges

5. **Missing high school data**: 4-5% of players have no high school listed
   - Existing backfill logic in cleaning.Rmd helps with this

### Edge Cases

- **Hyphenated schools**: Generally preserved (e.g., "Akron-Westfield")
- **Multi-word names**: No issues detected
- **Special characters**: Apostrophes, ampersands generally preserved
- **Charter schools**: Treated as public schools
- **Homeschool entries**: Mapped to "Homeschool" (standardized)

## Validation

### Quality Checks Performed

1. ✅ Duplicate detection: 5,807 duplicates found and resolved
2. ✅ Frequency analysis: Top schools verified (IMG Academy, New Hope, etc.)
3. ✅ State distribution: All 50 states + DC represented
4. ⏳ NCES validation: Pending NCES data acquisition
5. ⏳ Manual audit: Random sample check (to be performed)

### Success Metrics

| Metric | Target | Current Status |
|--------|--------|----------------|
| US school coverage | ≥95% | 37.1% (needs NCES data) |
| Player coverage | ≥95% | 44.2% (needs NCES data) |
| Deduplication rate | 15-25% | 28.6% (12,602 from 17,679) |
| International preservation | 100% | 100% ✓ |
| Error rate | <1% | TBD (needs audit) |

## Next Steps

### Phase 1: Completed ✓

- [x] Extract unique high schools from all roster years
- [x] Create normalization functions
- [x] Build duplicate resolution mapping
- [x] Add manual curated prep schools
- [x] Generate analysis files

### Phase 2: In Progress

- [ ] **Obtain NCES CCD data** (blocked by API access)
  - Option A: Manual download from https://nces.ed.gov/ccd/files.asp
  - Option B: Work with user to download locally
  - Option C: Use alternative data source

- [ ] **Match US public schools to NCES**
  - Implement fuzzy matching algorithm
  - Add NCES IDs to mapping
  - Validate matches

- [ ] **Expand manual curation**
  - Top 100 unmapped schools (by player count)
  - Common ambiguous names (Central, Liberty, etc.)
  - Known basketball powerhouse programs

### Phase 3: Future Enhancements

- [ ] Historical school tracking (mergers, closures, renames)
- [ ] Geocoding (add lat/long from NCES)
- [ ] School metadata (enrollment, public/private, athletic division)
- [ ] International school standardization
- [ ] Automated pipeline for new data

## References

### Data Sources

- **NCES Common Core of Data**: https://nces.ed.gov/ccd/
- **Urban Institute Education Data API**: https://educationdata.urban.org/
- **NCES Private School Universe Survey**: https://nces.ed.gov/surveys/pss/

### Documentation

- **CCD Data Dictionary**: https://nces.ed.gov/ccd/data_help.asp
- **School Level Codes**: 1=Primary, 2=Middle, 3=High, 4=Other/Alternative
- **NCES ID Format**: 12-digit unique identifier per school

## Contact & Maintenance

This standardization was created as part of the women's college basketball roster data project.

**Maintenance Schedule**:
- **Annual**: Re-run scripts when new roster data added
- **As needed**: Add manual mappings for new schools
- **Yearly**: Update NCES data (released each fall for prior year)

**Version**: 1.0 (Initial implementation)
**Last Updated**: 2025-11-20
