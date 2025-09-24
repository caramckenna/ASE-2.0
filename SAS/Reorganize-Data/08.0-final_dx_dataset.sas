/*****************************************************************************

Program:		08.0-final_dx_dataset

DATE:   		9/18/25

Created by:		Christina Chan

Purpose:  Create standardized DX dataset for EHR Sepsis Algorithm:  Diagnoses Codes


Datasets:   BASIC datasets (encounters in which antimicrobial was prescribed b/w admission & discharge)
			Daily Billing data (for ICD10 dx codes)

INPUT DATASETS:
		(1) raw.basic
		(2) edw.Dxcodes_allmgb_2021_2023;
				NOTE:  created in R as LEFT JOIN of PopEpiMap121124.csv to discharge_dx_2024-08-15.csv - on patientEncounterID

				This is a long dataset of ALL discharge diagnosis codes
				for every inpatient encounter at all MGB hospitals from 2021-2023
				-adm_id is based on population episode allMGB2015_2022 (includes hospital transfers)
				-removed eventDate variable to avoid duplicates (unless POA)
				- Daily-level; This table should include one row for each unique diagnosis_code/day combination.  
				 If a patient receives the same diagnosis code multiple times during the encounter, only a single row is needed.  


OUTPUT DATASET:
			raw.diagnosis
	
****************************************************************************************************************/


*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';

*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';



/*(1) Pull in Datasets of Interest */

	*(1a)  Pull in Basic dataset;
		proc sql;
    	create table basic_abbrev as
    	select adm_id, 
           patientID,
           admission_date,
		   admit_date_hosp,
		   discharge_date,
		   hospital_id,
           year
    	from raw.basic;
		quit;



	*(1b)  Pull in Diagnosis Code dataset;
		data dx;
		set edw.Dxcodes_allmgb_2021_2023;
		run;


/** (2) Merge DailyDx data to BASIC ; */
		/**RECALL: All BASIC encounters are those in which antimicrobial was prescribed b/w admission & Discharge dates */
		/**NOTE:  SERVICE_DATE is not included (inclusion of dx codes within admit/dc dates are already factored in)   **/


proc sql;
create table basic_dx as
select 	distinct a.*, 
		b.*
from basic_abbrev as a INNER JOIN dx  as b
on a.adm_id=b.adm_id ;
quit;



	proc sql;
	create table basic_dx2 as
	select distinct adm_id,
					patientID,
					admission_date,
				    admit_date_hosp,
					discharge_date,
					hospital_id,
					year,
					patientEncounterID,
					EMPI,
					count(icd10) as ndx label="N ICD10 dx codes per encounter",
					lineNBR,
					icd10 as icd10Dx, 
					STRIP(compress(icd10,'.')) as diagnosiscode,
					presentOnAdmissionDSC


	from basic_dx
	group by adm_id
	order by adm_id;
	quit;


/**(4)  SAVE TO PERMANENT DATASET **/
		data raw.diagnosis;
		set basic_dx2;
		run;


proc contents varnum data=raw.diagnosis;
run;

