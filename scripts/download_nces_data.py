#!/usr/bin/env python3
"""
Download NCES Common Core of Data for High School Standardization
This script downloads public school directory data from the Urban Institute Education Data API
"""

import requests
import pandas as pd
import time
import os
from pathlib import Path

# Create data directory
DATA_DIR = Path("data/nces")
DATA_DIR.mkdir(parents=True, exist_ok=True)

print("Starting NCES data download...\n")

def download_from_urban_api(year=2022):
    """
    Download school directory data from Urban Institute Education Data API
    Note: 2022 is used as it's widely available; 2023 may have limited data
    """
    print(f"Downloading data for year {year} from Urban Institute API...")

    base_url = f"https://educationdata.urban.org/api/v1/schools/ccd/directory/{year}/"

    all_schools = []
    page = 0
    max_pages = 100  # Safety limit

    while page < max_pages:
        try:
            # Build URL with parameters
            params = {
                'page': page,
                'per_page': 5000  # Maximum records per page
            }

            print(f"  Fetching page {page}...", end='', flush=True)

            response = requests.get(base_url, params=params, timeout=30)

            if response.status_code != 200:
                print(f" Error: HTTP {response.status_code}")
                break

            data = response.json()

            # Check if we got results
            if 'results' not in data or len(data['results']) == 0:
                print(" No more results")
                break

            all_schools.extend(data['results'])
            print(f" Got {len(data['results'])} schools (total: {len(all_schools)})")

            # Check if there's more data
            if 'next' not in data or not data['next']:
                print("  Reached last page")
                break

            page += 1

            # Rate limiting
            time.sleep(0.3)

        except Exception as e:
            print(f" Error: {e}")
            break

    if all_schools:
        df = pd.DataFrame(all_schools)
        print(f"\nTotal schools downloaded: {len(df)}")
        return df
    else:
        print("\nNo data downloaded")
        return None


def filter_high_schools(df):
    """Filter for high schools only"""
    print("\nFiltering for high schools...")

    # Filter criteria:
    # - school_level == 3 (High School) or 4 (Other)
    # - OR highest_grade >= 9
    # - school_status == 1 (Open)

    initial_count = len(df)

    # Filter for open schools
    if 'school_status' in df.columns:
        df = df[df['school_status'] == 1]

    # Filter for high schools
    # School level: 1=Primary, 2=Middle, 3=High, 4=Other
    high_school_df = df[
        ((df.get('school_level', 0).isin([3, 4])) |
         (df.get('highest_grade', 0) >= 9))
    ].copy()

    print(f"Filtered from {initial_count} to {len(high_school_df)} high schools")

    return high_school_df


def standardize_columns(df):
    """Standardize column names for easier use"""
    print("\nStandardizing column names...")

    # Column mapping
    column_map = {
        'ncessch': 'nces_school_id',
        'school_name': 'school_name',
        'lea_name': 'district_name',
        'leaid': 'nces_district_id',
        'state_location': 'state',
        'city_location': 'city',
        'zip_location': 'zip',
        'street_location': 'street',
        'phone': 'phone',
        'school_level': 'school_level',
        'lowest_grade': 'lowest_grade',
        'highest_grade': 'highest_grade',
        'enrollment': 'enrollment',
        'county_name': 'county',
        'county_code': 'county_code',
        'fips': 'state_fips'
    }

    # Rename columns that exist
    df = df.rename(columns={k: v for k, v in column_map.items() if k in df.columns})

    print("Standardization complete")
    return df


def download_state_by_state(year=2022):
    """
    Alternative method: Download state by state
    This is more reliable than trying to paginate through all results
    """
    print(f"Downloading state-by-state data for year {year}...")

    # FIPS codes for all US states and DC
    state_fips = {
        1: 'AL', 2: 'AK', 4: 'AZ', 5: 'AR', 6: 'CA', 8: 'CO', 9: 'CT', 10: 'DE',
        11: 'DC', 12: 'FL', 13: 'GA', 15: 'HI', 16: 'ID', 17: 'IL', 18: 'IN',
        19: 'IA', 20: 'KS', 21: 'KY', 22: 'LA', 23: 'ME', 24: 'MD', 25: 'MA',
        26: 'MI', 27: 'MN', 28: 'MS', 29: 'MO', 30: 'MT', 31: 'NE', 32: 'NV',
        33: 'NH', 34: 'NJ', 35: 'NM', 36: 'NY', 37: 'NC', 38: 'ND', 39: 'OH',
        40: 'OK', 41: 'OR', 42: 'PA', 44: 'RI', 45: 'SC', 46: 'SD', 47: 'TN',
        48: 'TX', 49: 'UT', 50: 'VT', 51: 'VA', 53: 'WA', 54: 'WV', 55: 'WI',
        56: 'WY'
    }

    all_schools = []

    for fips, state_abbr in state_fips.items():
        try:
            print(f"  Downloading {state_abbr} (FIPS {fips})...", end='', flush=True)

            url = f"https://educationdata.urban.org/api/v1/schools/ccd/directory/{year}/"
            params = {'fips': fips}

            response = requests.get(url, params=params, timeout=30)

            if response.status_code != 200:
                print(f" Error: HTTP {response.status_code}")
                continue

            data = response.json()

            if 'results' in data and data['results']:
                state_schools = data['results']
                all_schools.extend(state_schools)
                print(f" {len(state_schools)} schools")
            else:
                print(" No data")

            # Rate limiting
            time.sleep(0.2)

        except Exception as e:
            print(f" Error: {e}")
            continue

    if all_schools:
        df = pd.DataFrame(all_schools)
        print(f"\nTotal schools downloaded: {len(df)}")
        return df
    else:
        print("\nNo data downloaded")
        return None


def main():
    """Main execution"""

    # Try state-by-state download first (more reliable)
    print("Method 1: State-by-state download\n")
    df = download_state_by_state(year=2022)

    if df is None or len(df) == 0:
        print("\nMethod 1 failed. Trying Method 2: Full download\n")
        df = download_from_urban_api(year=2022)

    if df is None or len(df) == 0:
        print("\n" + "="*60)
        print("DOWNLOAD FAILED")
        print("="*60)
        print("\nPlease manually download NCES data from:")
        print("https://nces.ed.gov/ccd/files.asp")
        print("\nSave as: data/nces/nces_schools_manual.csv")
        return

    # Save raw data
    raw_file = DATA_DIR / "urban_api_raw.csv"
    df.to_csv(raw_file, index=False)
    print(f"\nSaved raw data: {raw_file}")

    # Standardize columns
    df = standardize_columns(df)

    # Filter for high schools
    hs_df = filter_high_schools(df)

    # Save high schools
    hs_file = DATA_DIR / "high_schools_current.csv"
    hs_df.to_csv(hs_file, index=False)
    print(f"Saved high school data: {hs_file}")

    # Create summary
    print("\n" + "="*60)
    print("DOWNLOAD COMPLETE")
    print("="*60)
    print(f"\nTotal high schools: {len(hs_df)}")

    if 'state' in hs_df.columns:
        print(f"States covered: {hs_df['state'].nunique()}")
        print(f"\nTop 10 states by school count:")
        print(hs_df['state'].value_counts().head(10))

    print("\nFiles created:")
    print(f"  - {raw_file}")
    print(f"  - {hs_file}")

    # Show sample
    print("\nSample of data:")
    cols_to_show = ['nces_school_id', 'school_name', 'city', 'state']
    available_cols = [c for c in cols_to_show if c in hs_df.columns]
    if available_cols:
        print(hs_df[available_cols].head(10).to_string(index=False))

    print("\nNECS data download complete!")


if __name__ == "__main__":
    main()
