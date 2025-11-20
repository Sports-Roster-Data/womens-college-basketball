# NCES Data Acquisition Instructions

The high school standardization system needs NCES (National Center for Education Statistics) Common Core of Data to match US public schools to their canonical names and IDs.

## Why We Need NCES Data

- **~13,000 US schools** in the dataset need verification against official records
- **Common school names** (Central, Liberty, Franklin, etc.) need city/state disambiguation
- **NCES IDs** provide unique identifiers for reliable matching
- **Official names** ensure canonical standardization

## Current Status

⚠️ **Automated download is blocked**: The Urban Institute Education Data API returns 403 errors, preventing automatic download.

## Manual Download Options

### Option 1: NCES Website (Recommended)

1. **Visit**: https://nces.ed.gov/ccd/files.asp

2. **Find the file**: Look for "Public Elementary/Secondary School Universe Survey"
   - Most recent complete year: **2023-24**
   - File name pattern: `ccd_sch_029_2324_w_0a_*.csv`

3. **Download**: Click the CSV download link

4. **Save to**: `data/nces/nces_schools_2023_24.csv`

### Option 2: Direct Publication Page

1. **Visit**: https://nces.ed.gov/pubsearch/pubsinfo.asp?pubid=2024251

2. **Download**: "2023-24 Common Core of Data (CCD) Universe Files, Version 1a"

3. **Extract**: The school-level CSV file from the ZIP

4. **Save to**: `data/nces/nces_schools_2023_24.csv`

### Option 3: State-Specific Download

If full download is too large, you can download state-by-state:

1. **Visit**: https://nces.ed.gov/ccd/elsi/

2. **Use the Interactive Tool**: Select school data by state

3. **Export**: CSV format for high schools only

4. **Combine**: Merge state files into one CSV

## What Fields We Need

The NCES file should contain these columns (at minimum):

| Column | Description | Required |
|--------|-------------|----------|
| `NCESSCH` or `ncessch` | 12-digit NCES school ID | ✓ Yes |
| `SCHNAM` or `school_name` | Official school name | ✓ Yes |
| `LCITY` or `city_location` | City name | ✓ Yes |
| `LSTATE` or `state_location` | Two-letter state code | ✓ Yes |
| `LSTREE` or `street_location` | Street address | Helpful |
| `LZIP` or `zip_location` | ZIP code | Helpful |
| `LEANM` or `lea_name` | School district name | Helpful |
| `SCHOOL_LEVEL` | School level (1=Elem, 2=Middle, 3=High, 4=Other) | Helpful |
| `PHONE` | School phone number | Optional |

## After Downloading

Once you have the NCES data file:

```bash
# 1. Verify the file exists
ls -lh data/nces/nces_schools_2023_24.csv

# 2. Run the matching script (to be created)
# python3 scripts/match_nces_schools.py

# 3. Review matches in data/
# cat data/nces_match_results.csv | head
```

## Alternative: Use MCP or Cached Data

If you have access to:

- **Model Context Protocol (MCP)** server with NCES data
- **Previously downloaded** NCES data from another project
- **University/institution license** to education databases

You can point the scripts to that data source instead.

## File Size Notes

- **Full CCD file**: ~100,000 schools, approximately 50-100 MB
- **High schools only**: ~20,000-25,000 schools, approximately 10-20 MB
- **Filtered for our dataset**: After matching, we only need ~13,000 schools

## Troubleshooting

### "File too large to download"

**Solution**: Use Option 3 (state-specific) or filter the data:
```python
import pandas as pd

# Load full file
df = pd.read_csv("nces_schools_full.csv", low_memory=False)

# Filter for high schools only
hs = df[df['SCHOOL_LEVEL'] == 3]  # 3 = High School

# Save filtered version
hs.to_csv("data/nces/nces_schools_2023_24.csv", index=False)
```

### "CSV format is different"

**Solution**: Our scripts will auto-detect column names. If they fail, manually rename columns to match the "What Fields We Need" table above.

### "Data is outdated"

**Note**: NCES data typically lags by 1-2 years. This is normal. We're standardizing school names, which rarely change, so 2023-24 data is sufficient for players through 2025-26 season.

## Next Steps After NCES Data is Available

1. Run matching script to match roster high schools to NCES schools
2. Review ambiguous matches (schools with similar names)
3. Update `data/high_school_mapping.csv` with NCES IDs
4. Re-run cleaning pipeline with enhanced mappings

## Questions?

If you encounter issues downloading or processing NCES data, you can:
1. Check NCES documentation: https://nces.ed.gov/ccd/ccddata.asp
2. Review this project's issue tracker
3. Proceed with current mapping (44% coverage) and enhance later
