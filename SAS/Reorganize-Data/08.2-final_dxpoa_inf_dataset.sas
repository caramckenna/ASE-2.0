/*****************************************************************************

Program:		08.2-final_dxpoa_inf_dataset

Created by:		Christina Chan

DATE:   		9/12/24
				6/25/25 - Incorporate updated Mapping file [ase2_ahrq_icd10_062625]
						  for ICD10 dx codes mapped to AHRQ infection categories (downloaded from CaraMcKenna GitRepo on 6/26/25) 

Purpose:  	Create summarized dataset of icd10 codes  with flags to identify 
			patient encounters associated with POA infection

INPUT DATASETS:
		    raw.diagnosis
						-this is all dx codes associated with a patient encounter
						 & merged to Pop Episode dataset via ptEncounterID/RN/PtID for 
						-includes lineNBR & POA infection flag (presentOnAdmissionDSC)


			ase2_ahrq_icd10_062625
						-This is a mapping file that links ICD10 dx codes to AHRQ Infection codes [can download from CaraMcKenna Git Repo]

OUTPUT DATASET:   raw.diagnosis_dxpoa_inf 	
					==>>  Each row represents a unique ICD10 code for AHRQ_Category_1 Infection associated with a patient encounter (by adm_id);  
						  There may be >1 icd10 code per encounter;  
						  Can use lineNBR variable to identify primary/principle dx codes  (lineNBR=1)


****************************************************************************************************************/

*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';

*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';


/***********************************************************/

/*(1) pull in updated DX code dataset (that includes POA and lineNBR);
			Can use lineNBR=1 to identify dx codes that are primary/principle diagnosis  **/


	*(1a) PULL IN final.diagnosis (includes lineNBR);

	proc sql;
	create table pop_dx_linenmbr as
	select adm_id, 
			patientID,
			admission_date,
			admit_date_hosp,
			discharge_date,
			empi,
			lineNBR,
			icd10dx,
			presentOnAdmissionDSC

	from raw.diagnosis ;
	quit;

	*(1b) Select distinct;
			proc sql;
			create table pop_dx_linenmbr2 as
			select distinct *
			from pop_dx_linenmbr;
			quit;

			



/******************************************************/
*(2) PULL IN ICD-10 MAPPING DOCUMENT;
		libname dxmap 'Z:\Projects\CDC National Sepsis Surveillance - ASE variants\Admin\mappings';

		data icd10_map;
		set dxmap.Ase2_ahrq_icd10_062625;
		run;



/********************************************************************/

*(3) Reformat POP_EPI_DX dataset (prep for merging)
			  RECALL:  This dataset is DXCODE_allMGB (all icd10 codes associated with every inpatient encounter at MGB); 


			*Limit to POA dx codes only;
			data Pop_dx_linenmbr3;
			set Pop_dx_linenmbr2;
			where presentOnAdmissionDSC='Yes';
			run;

			*reformat ICD10 variable;
				proc sql;
				create table Pop_dx_linenmbr4 as
				select *, compress(icd10dx,".") as icd10_new format  $9. length=9
						
				from Pop_dx_linenmbr3;
				quit;



/********************************************************************/
*(4) Merge in ICD10 mappings for POA infection codes;

		**(4a) Merge ICD10 Mappings to allMGB-ICD10-POA dataset;

				/****PREP MAPPING DSET TO ALIGN DATASETS that are merging (merge vbl must have identical formats):
						*DX & Mapping datasets must have identical formats; 
						icd10dx code: no decimals/  need to strip of surrounding apostrophes 

				
						*CONFIRM Max length of ICD10;
						proc sql ;
						create table check2a as 
						  select max(length(icd10_new)) as icd10_new_lngth 
						  from Pop_dx_linenmbr4;
						quit;

						proc sql ;
						create table check2b as 
						  select max(length(icd_10_cm_code)) as icd_10_cm_lngth 
						  from icd10_map;
						quit;
				****/

						*MERGE ;
							proc sql;
							create table Pop_dx_linenmbr_mapped as
							select 	a.*,
									b.*
							from Pop_dx_linenmbr4 as a LEFT JOIN icd10_map  as b
							on a.icd10_new=b.icd_10_cm_code;
							quit;


						*Refine/Limit ICD10 codes to mappings of interest (Column I, Infection Category 1);
							data Pop_dx_linenmbr_mapped2 ;
							set Pop_dx_linenmbr_mapped;
							dx_inf=1;  /*Add indicator variable to ID icd10 codes that map to infection category 1) */
							where infectious_category_1 ne ' ';
							run;


/** SAVE TO PERM DATASET*/

	data raw.diagnosis_dxpoa_inf;
	set Pop_dx_linenmbr_mapped2;
	run;



/**********************************/
/** FINAL dataset:  FINAL.DIAGNOSIS_DXPOA_INF)
	==>>  Each row represents a unique ICD10 code for POA infection associated with a patient encounter (by adm_id);

****************************************************************************************/



*Run QC and check against ELix dataset;
data check;
set final.diagnosis_dxpoa_inf;
year=year(admission_date);
run;


*RUn Freq counts by year;
proc freq;
tables year*dx_inf/missing  ;
run;



	*Explore LineNBR at the encounter level;
	proc sql;
	create table check_enc as
	select distinct 
	adm_id,
	year,
	min(lineNBR) as min_lineNBR,
	dx_inf
	from check
	group by adm_id
	order by adm_id;
	
	quit;

	*Add recode:  indicator to ID dx_poa flags based on primary dx code;
	data check_enc2;
	set check_enc;
	if min_lineNBR=1 then dxpoa_inf_primary=1;
	else dxpoa_inf_primary=0;
	label dxpoa_inf_primary='POA infection code, based on primary dx code (enc-level)';
	run;

	proc freq;
	tables year*dxpoa_inf_primary/missing nocol;
	run;
