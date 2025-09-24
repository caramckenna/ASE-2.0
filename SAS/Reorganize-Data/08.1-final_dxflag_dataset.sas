/*****************************************************************************

Program:		08.1-final_dxflag_dataset

Created by:		Christina Chan

Purpose:  	Create summarized dataset of dx_flags to identify encounters associated with specific icd10 codes/ POA flags 
			These are used in ASE 2.0 algorithm to calculate baseline values of specific labs (values are tweaked, depending on presence of specific icd10 codes);

				-dx_sepsis_poa  = dx codes for severe sepsis (R65.20) or septic shock (R65.21) - limited to POA only
				-dx_elix_renal  = dx codes for Elix moderate-severe renal failure (POA Only)
				-dx_elix_liver  = dx codes for Elix moderate-severe liver disease (POA Only)
				-dx_elix_cancer = dx codes for any Elix diagnoses for cancer (Leukemia, Lymphoma, SOlid Tumor without mets, solid 
				tumor with mets) - POA or not POA
				-dx_anemia_poa = dx codes for POA hemolytic anemia codes (D55x, D56x, D57x, D58x, and D59x)

DATE:   9/12/24
		9/26/24 - Add icd10 codes for POA hemolytic anemia (for bilirubin OD);
		11/7/24 - Add icd10 codes for POA dxicd10 infection codes  
		5/20/25 - Add icd10 codes for Sleep Apnea & Respiratory Failure (update to Respiratory OD):  
		6/26/25 - Incorporated updated mapping file for ALL dx_flags (icd10 codes):  dxmap.ase20_mappings_icd10dx_062625


INPUT DATASETS:
		    			raw.diagnosis
						Mapping file for ICD10 dx codes:  	dxmap.icd10_map_ase_2  [--> can download from CaraMcKenna GitRepo]

OUTPUT DATASET:  		raw.diagnosis_flags
						tmp.diagnosis_flag_raw

						Descriptions of output:
								raw.DIAGNOSIS_FLAGS
								Description of final dataset: Encounter-level; 
								This dataset ONLY reflects patient encounters who were associated with specific icd10 dx codes of-interest/ 
								POA flags for ASE 2.0  
								Each row represents a distinct patient encounter;

								TMP.DIAGNOSIS_FLAG_RAW  (aka, testmerge2)
								This is pop_dx5 dataset (original dx dataset, that has been cleaned & curated to single ICD10 code per row) 
								merged to mapping file
								then add recodes for the dx code categories of interest RECALL: THis is an uncollapsed version (so there may be
								 multiple rows per encounter)
								Dx codes ONLY reflect ICD10 codes that are POA= Yes or NO  (Excludes those that are 99,33, excluded)
			
					


****************************************************************************************************************/

*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';


*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';

/***********************************************************/

*(1) pull in updated DX code dataset (that includes POA);
data pop_dx;
set raw.diagnosis;
run;


*(2) add recode the reconfigures POA variable;
			proc freq ;
			tables presentOnAdmissionDSC/missing;
			run;


					*(2) ADD RECODE FOR POA STATUS (NUMERIC FORMAT);
						data pop_dx2;
						set pop_dx;
						year=year(admission_date);
						if presentOnAdmissionDSC='Yes' 	then poa=1;
						if presentOnAdmissionDSC='No' 	then poa=0;
						if presentOnAdmissionDSC='Exempt from POA reporting' then poa=33;  *3=Exempt from pOA reporting *;
						if presentOnAdmissionDSC in ('NA', 'Unknown', 'Clinically Undetermined') then poa=99;
						if presentOnAdmissionDSC in (' ') then poa=.;
						label poa='POA INDICATOR(num) [33=exempt from reporting; 99=NA/Unknwn/clin undetermined]';
						run;


								proc freq;
								tables presentOnAdmissionDSC*poa/missing norow nocol nopct;
								run;

				/*(2a) LIMIT TO VBLS OF INTEREST & Select DISTINCT;
				    * Need to Remove leading/trailing blanks from DiagnosisCode;
					NOTE:   This dataset ONLY includes ALL ICD10 codes & POA (regardless of POA status) ***/


					proc sql;
					create table pop_dx3 as
					select distinct adm_id, year,
									icd10Dx as icd10_og, 
									STRIP(COMPBL(compress(icd10Dx, '.'))) as icd10,
									presentOnAdmissionDSC, 
									poa
					from  pop_dx2  ;   
					quit;

						*CONFIRM Max length of ICD10 (==7);
								proc sql ;
								create table test as 
								  select *, length(icd10) as icd10_lngth
								  from pop_dx3
								  ;
								quit;

*(3) pull in Dx code mappings dataset;

		libname dxmap 'Z:\Projects\CDC National Sepsis Surveillance - ASE variants\Admin\mappings';

		data icd10map;
		set dxmap.Ase2_icd10_codes_062625;
		run;


					*CONFIRM Max length of ICD10;
						proc sql ;
						create table check2a as 
						  select max(length(icd10_cm_dx)) as icd10_cm_dx_lngth /*into :max_length trimmed */
						  from icd10map
						  ;
						quit;

						proc sql ;
						create table check2b as 
						  select max(length(icd10)) as icd10_lngth /*into :max_length trimmed */
						  from pop_dx3
						  ;
						quit;
	

*(4) merge in mappings;
**NOTE:  will use INNER JOIN (am only interested in ICD10 codes that match up to dx codes of interest);

		proc sql;
		create table testmerge as
		select a.*, b.*
		from pop_dx3 as a LEFT JOIN icd10map as b 
		on a.icd10=b.icd10_cm_dx;
		quit;

			** SAVE TESTMERGE TO TMP DATASET-- file size may be large, so this minimizes processing time if you need to stop mid-point;
				/**	testmerge2 or tmp.diagnosis_flag_raw:
				This is pop_dx3 dataset (original dx dataset, that has been cleaned & curated to single ICD10 code per row)
				THEN merged to mapping file 
				THEN add recodes for the dx code categories of interest 

				RECALL: THis is an uncollapsed version (so there may be multiple rows per encounter)
				Dx codes ONLY reflect ICD10 codes that are POA= Yes or NO  (Excludes those that are 99,33, excluded)  	***/

					data tmp.diagnosis_flag_raw;
					set testmerge;
					run;
					/******/

					proc freq data=testmerge;
					tables dxcat_broad presentOnAdmissionDSC/missing;
					run;


					*Pull in tmp.diagnosis_flag_raw dataset (testmerge);
					DATA testmerge;
					set tmp.diagnosis_flag_raw;
					run;



*ADD RECODES FOR DX_ANEMIA_POA;
	data testmerge2;
	set testmerge;
	if POA=1 and substr(icd10,1,3) in ('D55', 'D56', 'D57', 'D58', 'D59') then dx_anemia_poa=1; 
	else dx_anemia_poa=0;
	run;



/****************************************************************************************
*NEXT:  Want to identify cases (at the encounter-level) that meet criteria for
specific dx_code categories (for algorithm only))

		*Add recodes for categories;
		*then collapse to encounter level;
*******************************************************************************************/


*(5) Add recodes for categories;

	*(5a)  Limit to dataset, based on POA status;
		   *RECALL:  Sepsis DX codes require POA flag.
					 Renal Disease and Liver Disease both require POA flags.   
					 Resp Failure, Sleep Apnea, Cancer Comos (Leuk, lymphoma, solid tumor with/out mets) do NOT require POA flags;
		data testmerge2a;
		set testmerge2;

		if dxcat_broad='icd10_sepsis_poa' 	and poa=1 then dx_sepsis_poa=1; else dx_sepsis_poa=0;
		if dxcat_broad='elix_renal' 		and poa=1 then dx_elix_renal=1; else dx_elix_renal=0;
		if dxcat_broad='elix_liver' 		and poa=1 then dx_elix_liver=1; else dx_elix_liver=0;
		if dxcat_broad='elix_cancer' 				  then dx_elix_cancer=1; else dx_elix_cancer=0;
		if dxcat_broad='dx_osa'				          then dx_osa=1; 		 else dx_osa=0;
		if dxcat_broad='dx_rf'				          then dx_rf=1; 		 else dx_rf=0;

		run;


	*(5b)Collapse to encounter level;
		proc sql;
		create table testmerge3 as 
		select distinct adm_id,
				year, 
				max(dx_sepsis_poa)  as dx_sepsis_poa,
				max(dx_elix_renal)  as dx_elix_renal,
				max(dx_elix_liver)  as dx_elix_liver,
				max(dx_elix_cancer) as dx_elix_cancer,
				max(dx_anemia_poa)  as dx_anemia_poa,
				max(dx_osa)  		as dx_osa,
				max(dx_rf)  		as dx_rf


		from testmerge2a
		group by adm_id
		order by adm_id;
		quit;


	*[5c] Add variable labels;

		data testmerge4;
		set testmerge3;
		label dx_sepsis_poa   = 'icd10 dx for severe sepsis (R65.20) or septic shock (R65.21) -POA only';
		label dx_elix_renal   = 'icd10 dx for Elix mod-severe renal failure (POA Only)';
		label dx_elix_liver   = 'icd10 dx for Elix mod-severe liver disease (POA Only)';
		label dx_elix_cancer  = 'icd10 dx for any Elix diagnoses for cancer (Leukemia, Lymphoma, Solid tumor with/without mets) - POA or not POA';
		label dx_anemia_poa   = 'icd10 dx for  hemolytic anemia codes POA (D55x, D56x, D57x, D58x, and D59x)';
		label dx_rf = 'icd10 dx for acute or unspec respiratory failure';
		label dx_osa	  = 'icd10 dx obstructive sleep apnea';
		run;



/**(6)  SAVE TO PERMANENT DATASET **/
		data raw.diagnosis_flag;
		set testmerge4;
		run;



 /************************************************************************************************************************/
 /************************************************************************************************************************/


*Run QC and check against ELix dataset;

*RUn Freq counts by year;
proc freq data=raw.diagnosis_flag;
tables year*(dx_sepsis_poa 
dx_elix_renal 
dx_elix_liver 
dx_elix_cancer
dx_anemia_poa 
dx_osa
dx_rf)/missing;
run;


proc freq data=raw.diagnosis_flag;
tables dx_sepsis_poa 
dx_elix_renal 
dx_elix_liver 
dx_elix_cancer
dx_anemia_poa 
dx_osa
dx_rf/missing;
run;
