# ASE 2.0 - Adult Sepsis Event Algorithm

The Adult Sepsis Event (ASE) version 2.0 algorithm identifies sepsis cases using standardized, electronically computable criteria. This repository contains implementations in multiple programming languages for use with electronic health record data.

## Overview

The ASE 2.0 algorithm detects sepsis by identifying:
1. **Presumed Serious Infection** - Evidence of infection through blood cultures, diagnosis codes, and antibiotic treatment
2. **Organ Dysfunction** - Clinical markers across six organ systems (cardiovascular, respiratory, metabolic, renal, hepatic, coagulation)

## Repository Structure

```
ASE-2.0/
├── README.md           # This file - project overview
├── R/                  # R implementation
├── SAS/                # SAS implementation
├── docs/               # Algorithm specification and documentation
└── mapping/            # Reference mapping files
```

## Support and Contributions

These implementations were designed to work with a specific healthcare system. Adaptation to your specific EHR system may require:

- Column name mapping
- Data format conversions  
- Custom diagnosis/medication code mappings
- Performance optimization for large datasets

For questions about the ASE algorithm, see documentation in docs/. For implementation support, open an issue in this repo or contact the maintainer.
