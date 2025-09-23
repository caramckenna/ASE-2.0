# ASE 2.0 Algorithm — R Implementation

This repository contains R functions that implement the Adult Sepsis Event (ASE) 2.0 algorithm for identifying sepsis cases in electronic health record data. The algorithm identifies presumed serious infections and organ dysfunction to detect sepsis events.

## Overview

The ASE algorithm consists of two main components:
1. **Presumed Serious Infection (PSI)** - Identifies infection events based on blood cultures, diagnosis codes, and qualifying antibiotic days
2. **Organ Dysfunction (OD)** - Detects dysfunction across six organ systems using clinical markers

## System Requirements

- **R Version**: ≥ 4.1
- **Required Packages**: 
  ```r
  install.packages(c("tidyverse", "data.table", "lubridate"))
  ```

## Core Functions

### `ase_2()` - Main Wrapper Function
Single-call interface that runs the complete ASE algorithm.

```r
final_ase <- ase_2(
  input_data_dir  = "/path/to/your/data",
  input_data_ver  = "v1", 
  micro_path      = "/path/to/microbiology.csv",
  ep_dsn          = episodes_dataframe,
  epmap_dsn       = episode_mapping_dataframe,
  ase_mapping_dir = "./mapping",
  days_co_ho      = 7,
  days_ho_ho      = 14,
  save_paths      = list(
    psi_cohort = "/path/to/psi_output.Rds",
    ase        = "/path/to/final_ase.Rds"
  )
)
```

### `ase_2_psi()` - Presumed Serious Infection
Identifies infection events and qualifying antibiotic days.

### `ase_2_od()` - Organ Dysfunction Detection  
Processes PSI cohort to identify organ dysfunction and final ASE events.

## Required Input Data

### Episode Data (`ep_dsn`)
Core hospitalization data with these **required columns**:

| Column | Type | Description |
|--------|------|-------------|
| `patientID` | character | Unique patient identifier |
| `episodeID` | character | Unique hospitalization identifier |
| `startDT` | Date | Start of hospitalization date |
| `hospitalDischargeDT` | Date | Hospital discharge date |
| `sex` | character | "MALE", "FEMALE", or missing |
| `dischargeDispositionGroup` | character | HOME, HOSPICE, DEAD, ACUTE CARE HOSPITAL |
| `deathDT_derived` | Date | Date of death (if applicable) |

### Episode Mapping Data (`epmap_dsn`) 
Links patient/episode IDs to encounter IDs. 
Useful if multiple episodes of hospitalization have been combined.

| Column | Type | Description |
|--------|------|-------------|
| `patientID` | character | Patient identifier (matches episode data) |
| `episodeID` | character | Episode identifier (matches episode data) |
| `patientEncounterID` | character | Encounter/visit identifier |
| `empi` | character | Enterprise patient index |

### Microbiology Data (`micro_path`)
Blood culture data:

| Column | Type | Description |
|--------|------|-------------|
| `site_clean` | character | Must contain "BLOOD" for blood cultures |
| `MRN` | character/numeric | Medical record number |
| `coll_datetime` | character | Collection datetime (YYYY-MM-DD HH:MM:SS) |
| `CSN` | character | Contact serial number (encounter ID) |

### Clinical Data Files
Files in `input_data_dir` with naming pattern `{type}_{input_data_ver}.csv`:

**Medications:**
- `abx_{ver}.csv` - Antibiotics
- `antifungals_antivirals_{ver}.csv` - Antifungals/antivirals  
- `vasopressors_{ver}.csv` - Vasopressor medications

**Vital Signs:**
- `bp_{ver}.csv` - Blood pressure readings
- `o2_devices_{ver}.csv` - Oxygen delivery devices

**Laboratory Results:**
- `lactate_{ver}.csv` - Lactate levels
- `creatinine_{ver}.csv` - Creatinine levels  
- `total_bilirubin_{ver}.csv` - Total bilirubin
- `platelets_{ver}.csv` - Platelet counts

**Other:**
- `discharge_dx_{ver}.csv` - Discharge diagnoses
- `mrn_{ver}.csv` - Medical record numbers
- `daily_{ver}.csv` - Daily comfort care flags

### Mapping Files
Required files in `ase_mapping_dir`:

- `ase-icd10-codes.csv` - ICD-10 diagnosis code mappings
- `ase-ahrq-icd10-codes.csv` - AHRQ infectious disease codes  
- `ase-medications-list.csv` - Medication formulary mappings

## Expected Data Formats

### Medication Data
Required columns: `patientID`, `medicationTakenDTS`, `adminRouteMapped`, `medNameMapped`

### Laboratory Data  
Required columns: `patientID`, `specimenTakenDTS`, `resultN`

### Vital Signs Data
Required columns: `patientID`, `recordedDTS`, plus measurement-specific fields

## Output Data

The final ASE dataset contains one row per sepsis event with these key variables:

| Variable | Description |
|----------|-------------|
| `ase` | Sepsis event flag (0/1) |
| `ase_dt` | Date of sepsis event |
| `ase_type` | "CO" (community-onset) or "HO" (hospital-onset) |
| `inf_onset_dt` | Infection onset date |
| `od_cv`, `od_respiratory`, etc. | Organ dysfunction flags |
| Individual OD dates | `od_cv_dt`, `od_respiratory_dt`, etc. |

## Adapting to Your Data

### Column Name Mapping
If your data uses different column names, you'll need to rename them to match the expected schema or modify the functions.

### Data Type Conversions
Ensure date columns are properly formatted and numeric laboratory values are clean.

### Missing Data Handling
The algorithm includes built-in filters for missing or invalid data, but review your data quality first.

### Diagnosis Code Systems
The provided mapping files use ICD-10-CM codes. You may need to create custom mappings for:
- Different coding systems (ICD-9, local codes)
- Institution-specific medication formularies
- Local diagnosis groupings

## Performance Considerations

- **Large datasets**: Consider processing in batches by date ranges
- **Memory usage**: The algorithm creates many intermediate datasets - monitor RAM usage
- **Processing time**: Expect 10-30 minutes for typical hospital datasets (50K+ episodes)
- **Qualifying Antibiotic Days (QAD)**: This is the most computationally intensive step

## Troubleshooting

### Common Issues
1. **Date format errors**: Ensure all datetime columns use standard formats
2. **Missing mapping files**: Verify all required CSV files exist in `ase_mapping_dir`
3. **Memory errors**: Reduce dataset size or increase available RAM
4. **No PSI cases found**: Check that microbiology and medication data overlap with episodes

## Example Workflow

```r
# Load required libraries
library(tidyverse)
library(data.table)
library(lubridate)

# Prepare your data
episodes <- readRDS("my_episodes.Rds")
episode_map <- readRDS("my_episode_mapping.Rds")

# Run ASE algorithm
ase_results <- ase_2(
  input_data_dir = "/data/clinical_files",
  input_data_ver = "2024q1",
  micro_path = "/data/microbiology_2024q1.csv", 
  ep_dsn = episodes,
  epmap_dsn = episode_map,
  ase_mapping_dir = "./mapping_files",
  save_paths = list(
    psi_cohort = "./output/psi_cohort.Rds",
    ase = "./output/final_ase_results.Rds"
  )
)

# Review results
summary(ase_results)
table(ase_results$ase_type)
```

## Support

This implementation was designed for a specific healthcare system's data structure. Adaptation to other systems will likely require:

- Column name modifications
- Data type adjustments  
- Custom diagnosis/medication mappings
- Validation against your clinical workflows

For questions about the ASE algorithm specification, refer to the official documentation. For code questions, open an issue in this repo or contact the maintainer.