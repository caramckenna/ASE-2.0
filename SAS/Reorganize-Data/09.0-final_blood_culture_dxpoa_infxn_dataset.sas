/******************************************************************************************************
Program:		09.0-final_blood_culture_dxpoa_infxn_dataset

Created by:		Christina Chan

			
DATE:		12/04/24 	- Update for ASE 2.0:  BCX_DRAWN_DAY now reflects bc_collection date relative to first day in hospital (admission to ED or inpatient, whichever occurs first)
								   Previous versions of BCX_DRAWN_DAY reflect bc_collection date relative to admission as inpatient

				12/18/24 	- Cutoff for CO/HO-ASE is changed to 4 days (from 3)
				5/5/25 		- update rule for "DC alive on QAD3" is allowed if pt had BOTH blood culture -AND- DXPOA_primary   (Change: dxpoa_inf to dxpoa_inf_primary=1)
				7/1/25: 	- Add new row of data for blood culture draws that occur on/after day 4 in conjunction with POA Infection code that is principle diagnosis;
										This allow them to be considered for HO-ASE (in ASE algorithm) if there are no QAD's or OD data during days 1-3
				8/1/25:  	-Tweak #1  to code that adds extra records for encounters where dxpoa_inf_primary=1. Want to retain record of original bcx day 
						 			-remove dxpoa_inf from final dataset, to simplify/avoid confusion
				8/14/25:  -Limit all blood cultures to records with collection dates falling between admission & discharge (formerly pulling in bw admit-2 and discharge)
				8/15/25:  -Limit all blood cultures to origina time window:  hosp day 1 (admit-1) and discharge)
				8/26/25: 	-Tweak #2 to code that adds extra records for encounters where dxpoa_inf_primary=1. Limit this change ONLY to records where there are no other bcx_days before days 1,2,3


Purpose:		Combine Blood Culture with DXPOA_inf data to create standardized input Blood culture-DXPOA inf dataset

					STEPS:
					-Pull in BASIC dataset
					-Merge to Blood culture dataset (enc-level, any blood culture during encounter, Y/N)
					-Merge to Diagnosis_dxpoa_inf dataset (to identify encounters with POA infection code (principal dx only)
					-Merge in Daily-level Blood Culture dataset
					-Create INFXN_ANCHOR_DAY  (based on cutoff for CO/HO-ASE)



INPUTS: 				
				raw.basic
				raw.blood_culture
				raw.diagnosis_dxpoa_inf



OUTPUTS:		raw.blood_culture_dxpoa_inf
					==>> This is a subset of patients who received antibiotics, and either had a blood culture -AND/OR- icd10 POA dx code for infection (Primary/Principal DX only); 
					==>> includes INFECTION_ANCHOR_DAY, which has been adjusted to account for presence of icd10 POA infection code (with/out BC);
					==>> will use this as input datasts for EHR_infection & EHR_organ_dysfunction programs

				tmp.bloodculture_dxpoa;
					==>> This is daily-level dataset reflecting blood culture & bcx_drawn day, and/or icd10 dx pOA infection code 
						(including flag for primary dxpoa infections);


********************************************************************************************************/


*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';


*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';



/*****I. BASIC DATASET ****/

*(1)  Pull in Basic dataset;
	*Limit to variables of interest from BASIC;

	proc sql;
	create table basic_fnl as
	select adm_id, 
			patientId,
			admission_date, /*ASE 2.0 */
			admit_date_ed,
			admit_date_hosp,  /*ASE 1.0 */
			discharge_date,
			(discharge_date-admission_date)+1 as discharge_day,
			hospital_id,
			year
			from raw.basic; 
	quit;

	/****/



/*****II.  BLOOD CULTURE DATASET ****/
*(2)  Pull in Blood Culture dataset;

	/* Create records for each day blood culture was drawn */
	proc sql;
	    create table bloodculture_draw as
	        select distinct Adm_ID,
	                        PatientID, 
	                        bcx_drawn_day
	        from raw.blood_culture;
	quit;


	/*Create discharge_day */
	proc sql;
	    create table bloodculture_draw2 as
			select a.*, b.admission_date,  b.discharge_date, b.discharge_day

	        from bloodculture_draw as a LEFT JOIN
	             basic_fnl as b
	        on a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
	            a.bcx_drawn_day <=  b.discharge_Day;
	quit;


	/*[08/14/25]: Limit to blood cultures collected between admission-1 (hosp day 0) & discharge */
		data bloodculture_draw3;
		set bloodculture_draw2;
		where bcx_drawn_day ge 0;
		run;

	*Identify all encounters from BASIC  with AT LEAST 1 blood draw;

	proc sql;
	create table bcx_enc as
	select distinct adm_id, 
					1 as blcx_enc label='At least 1 blood culture during encounter'
	from bloodculture_draw3;
	quit;

/*****III. AHRQ_INFXN dataset - Principal Diagnosis ONLY****/

*DXPOA - Primary DX;

	/** POA Infection code / Principal Diagnosis**/
	/*  Create subset of patients with no blood draw,  but had a POA dx_infection code (as principle DX) ****/

		/* Dataset of icd10 POA Infection  code:    raw.diagnosis_dxpoa_inf

					==>> This is all POA icd10 codes associated with every encounter.  
						 Then merged to AHRQ mapping file for POA infection codes.

					 	 Can use lineNBR variable to identify which of these mapped ICD10 codes was listed as  principle/primary 
						 diagnosis **/


*(3)  Pull in DXPOA dataset:  raw.Diagnosis_dxpoa_inf ;
data dxpoa;
set raw.Diagnosis_dxpoa_inf;
run;


	*(3a) Create list of all admid's where dx_inf=1 (regardless of primary or not);
	proc sql;
	create table dxpoa_all as
	select distinct adm_id, 
					dx_inf label='ICD-10 code for AHRQ infection category 1'
	from dxpoa;
	quit;


	*(3b)Create subset of dxINF records with a primary diagnosis (where lineNBR=1);
	data dxpoa2;
	set dxpoa;
	where lineNBR=1;
	run;

				*(3b-1)Get Adm_ID for encounters with a DX_POA code that is primary dx;
				proc sql;
				create table dxpoa_id as
				select distinct adm_id,
								min(lineNBR) as min_lineNBR,
								dx_inf
				from dxpoa2
				group by adm_id
				order by adm_id;
				quit;

					*(3b-2)Add recode:  indicator to ID dx_inf flags based on primary dx code;
					data dxpoa_id2;
					set dxpoa_id;
					if min_lineNBR=1 then dxpoa_inf_primary=1;
					else dxpoa_inf_primary=0;
					label dxpoa_inf_primary='Infection code, based on principal dx code (enc-level)';
					run;

					*(3b-3) select distinct;
					proc sql;
					create table dxpoa_id3 as
					select distinct adm_Id, dxpoa_inf_primary
					from dxpoa_id2;
					quit;

	*(3c) Merge back to MAIN (dxpoa_all dataset - all admids where dx_inf=1);
		proc sql;
		create table dxpoa_all_final_ as
		select a.*, b.dxpoa_inf_primary
		from dxpoa_all as a LEFT JOIN dxpoa_id3 as b
		on a.adm_id=b.adm_id;
		quit;

		data dxpoa_all_final;
		set dxpoa_all_final_;
		if dxpoa_inf_primary=. then dxpoa_inf_primary=0;
		run;

				proc freq;
				tables dx_inf dxpoa_inf_primary dx_inf*dxpoa_inf_primary/missing;
				run;

	*(3d) Merge DXPOA data to basic data (we are only interested in encounters from the BASIC dataset 
		 - these pts received antimicrobial during encounter);
	proc sql;
	create table basic_dxpoa as
	select a.adm_id, b.*
	from basic_fnl as a INNER JOIN dxpoa_all_final as b
	on a.adm_id=b.adm_id;
	quit;
		/**==> n= XXX encounters who had a Dx Code for infection -AND- received antimicrobial (per BASIC dataset );  
		This is a subset of the BASIC dataset ****/


/****************************************************************************************************************************/
/****************************************************************************************************************************/

/***** IV.  Merge BLOOD CULTURE & DXPOA_INFECTION ****/

	*(4) Merge BASIC_FNL to BASIC_DXPOA, and then to BCX_ENC  (enc-level blood culture data: blcx merged to BASIC);

	    **Want LEFT JOIN to Basic ;
					proc sql;
					create table basic_dxpoa as
					select  a.adm_id , 
							b.*
					from basic_fnl as a LEFT JOIN basic_dxpoa  as b
					on a.adm_id=b.adm_id;
					quit;


				**Then another LEFT JOIN to BCX_ENC ;
							proc sql;
							create table basic_dxpoa_bcx as
							select  a.* , 
									b.*
							from basic_dxpoa as a LEFT JOIN bcx_enc  as b
							on a.adm_id=b.adm_id;
							quit;


							*Then delete records with missing data for bcx/dx_inf/dxpoa_primary;
								data basic_dxpoa_bcx2;
								set basic_dxpoa_bcx;

								if blcx_enc=. then  blcx_enc= 0;
								if dxpoa_inf_primary=. then dxpoa_inf_primary=0;
								if dx_inf=. then dx_inf=0;

								if (blcx_enc=0 and dxpoa_inf_primary=0  and dx_inf=0) then delete;
								run;


*QC;
proc freq data=basic_dxpoa_bcx2;
tables blcx_enc dxpoa_inf_primary dx_inf/missing;
run;




	*(5) Refine subset of Encounters with/out blood culture vs. Primary AHRQ Infection code;
	  ****Want to keep encounters where:  blcx_enc=1 or (blcx_enc=0 and dxpoa_inf_primary=1);
			
			data basic_bcx_dxpoa_enc;
			set basic_dxpoa_bcx2;
			where  blcx_enc=1 or dxpoa_inf_primary=1;
			run;	
		/*FINAL dataset n= XXXXX 
			encounters that had Blood culture and/or primary DXPOA infection code  **/

		/*		proc freq;
				tables dx_inf dxpoa_inf_primary blcx_enc  blcx_enc*(dx_inf dxpoa_inf_primary) dx_inf*dxpoa_inf_primary /missing;
				run;
		*/


/**********************************************************************************************************/
		/* NEXT STEPS: Create final subset of patient encounters with:
				   (1) at least 1 blood culture 
			-OR- (2) primary DXPOA_infection code with NO blood culture.
		  			 All of these encounters received antibiotics b/w admission  DC (basic daaset);

				  *RECALL:  BASIC dataset reflects all inpatient encounters  for which there is an antimicrobial prescribed  
				   b/w admit and discharge_dates ;
/**********************************************************************************************************/

  *(6) MERGE basic_bcx_dxpoa_enc dataset (enc-level blood_culture/poa_inf)  to  BLOODCULTURE_DRAW3 (daily-level, all blood draws & bcx_drawn_day) */
		*add BCX_DRAWN_DAY variable;

		proc sql;
		create table  bloodculture_dxpoa as
		select distinct a.*, b.*
		from basic_bcx_dxpoa_enc as a LEFT JOIN   bloodculture_draw3 as b
		on a.adm_id=b.adm_id;
		quit;

			*Limit to vbls of interest;
			proc sql;
	    	create table bloodculture_dxpoa2 as
	        select distinct adm_id,
				blcx_enc as blood_culture label='Any blood culture during encounter',
				bcx_drawn_day,
				dx_inf as dxpoa_inf,
				dxpoa_inf_primary

			from bloodculture_dxpoa;
			quit;

				*save as TMP dataset ;
				data tmp.bloodculture_dxpoa;
				set bloodculture_dxpoa2;
				run;
				*==>> This is daily-level dataset reflecting blood culture & bcx_drawn day, 
					and/or icd10 dx pOA infection code (including flag for primary dxpoa infections);



	*(7) ADD RECODE FOR INFECTION ANCHOR DAY **/

		*(7a) For encounters with a blood culture, get first blood culture day;
		proc sql;
		create table bloodculture_dxpoa3 as
		select *,
				min(bcx_drawn_day) as min_bcxdrawnday
		from bloodculture_dxpoa2
		group by adm_id
		order by adm_id;
		quit;

		/*(7b) Define Infection Anchor Day using Blood culture or Principal AHRQ infection code 
			 [ASE 2.0 (updated 12/18/24)]:  
			  infxn window anchor date = blood culture day 
				-OR-  Day 1 if AHRQ infection code present AS PRIMARY DIAGNOSIS  and no bcx drawn prior to day 4
			  NOTE:  if 2+ bcx drawn, this logic only applies to the first occuring bcx_day */


/** Hospital day 1 (day 1 = day of hospital arrival) if infection/sepsis is the principal diagnosis and no blood culture drawn by day 3*/

		data bloodculture_dxpoa4;
		set bloodculture_dxpoa3;
		if  dxpoa_inf_primary=1  and blood_culture=1 then do;
			if (min_bcxdrawnday ge 4 	and 	min_bcxdrawnday = bcx_drawn_day) then 	infxn_anchor_day =1; 
			else 																		infxn_anchor_day = bcx_drawn_day;
		end; 

		if dxpoa_inf_primary=1 and blood_culture=0 then infxn_anchor_day=1;
		if dxpoa_inf_primary=0 and blood_culture=1 then infxn_anchor_day= bcx_drawn_day;

		run;


		/*[NEW: 7/1/25]; [8/26/25] Limit this step to cases where min_bcxdrawnday ge 4 */
		/*(7c) Create NEW dataset #1 with extra row for infxn_anchor_day when dxpoa_inf_primary=1;
				RECALL:  Want to capture the bcx_drawn_day for cases where: "dxpoa_inf_primary=1 and blood_culture=1 and bcx_drawn_day ge 4"  
			    WHY?  If there are no QAD's or OD around before days 1-3, then want to consider Infection Episodes that occur on/after day 4  */

		data bloodculture_dxpoa4_extra;
		set bloodculture_dxpoa3;
		if  min_bcxdrawnday ge 4 	then do;
			if	dxpoa_inf_primary=1  and bcx_drawn_day ge 4 	 then 	infxn_anchor_day =1; 
		end;
		run;


			data bloodculture_dxpoa4_extra2;
			set bloodculture_dxpoa4_extra;
			if infxn_anchor_day=. then delete;
			run;

			*Only want one record per adm_id, so select adm_id with min(bcxdrawnday);
				proc sql;
				create table bloodculture_dxpoa4_extra3 as 
				select *, min(bcx_drawn_day) as minday
				from bloodculture_dxpoa4_extra2
				group by adm_id
				order by adm_id;
				quit;

					data bloodculture_dxpoa4_extra_fnl;
					set bloodculture_dxpoa4_extra3;
					where bcx_drawn_day=minday;
					drop minday;
					run;

		/*NEW:  8/1/25 */
		/*(7d) *Create NEW dataset #2 that captures blood_culture_days that were reset to infxn_anchor_day=1 per this RULE: 
							  ["dxpoa_inf_primary=1 and blood_culture=1 and bcx_drawn_day ge 4 then infxn_anchor_day=1"], 
									this only applies if there is only 1 row per encounter   */
		data bloodculture_dxpoa4_extraextra;
		set bloodculture_dxpoa3;
		if  dxpoa_inf_primary=1  and blood_culture=1 then infxn_anchor_day = bcx_drawn_day;
		run;

		data bloodculture_dxpoa4_extraextra2;
		set bloodculture_dxpoa4_extraextra;
		if infxn_anchor_day=. then delete;
		run;


		*(7e) CONCATATE DATASETS;
		data bloodculture_dxpoa6;
		set bloodculture_dxpoa4 	bloodculture_dxpoa4_extra_fnl 	bloodculture_dxpoa4_extraextra2 ;
		run;

			*Dedupe/select distinct;
			proc sql;
			create table bloodculture_dxpoa7 as
			select distinct *
			from bloodculture_dxpoa6;
			quit;

				proc sort;
				by adm_id bcx_drawn_day;
				run;


	*(8) REARRANGE VBLS/ add patientID from BASIC;
		proc sql;
		create table bcx_dxpoa as
		select distinct a.adm_id,
				b.patientID,
				b.admission_date, 
				b.admit_date_hosp,
				b.discharge_date,
				b.discharge_day, 
				a.dxpoa_inf_primary,
				a.blood_culture,
				a.bcx_drawn_day,
				a.infxn_anchor_day

		from bloodculture_dxpoa7 as a LEFT JOIN basic_fnl as b
		on a.adm_id=b.adm_id;
		quit;

	*(9)  SAVE FINAL VERSIONS OF BASIC BC/DXPOA;
		
		*NOTE:   These are a subset of patients who received antibiotics, and either had a blood culture 
				-AND/OR- icd10 POA dx code for infection (Primary/Principal DX only)
				 Infection_anchor_date has been adjusted to account for presence of icd10 POA infection code (with/out BC);

		*NOTE:  Will use this dataset in the Organ Dysfunction dataset ***;

		data raw.blood_culture_dxpoa_inf;
		set bcx_dxpoa;
		where blood_culture=1 or dxpoa_inf_primary=1;
		run;




/***** FINAL QC: **************************************************************************************************************/

title 'QC for BLOOD_CULTURE_DXPOA_INF dataset (ASE 2.0)';
proc freq data=raw.blood_culture_dxpoa_inf;
tables blood_culture dxpoa_inf_primary blood_culture*(dxpoa_inf_primary) dxpoa_inf_primary/  norow nocol nopct  missing;
run;


title 'QC for BLOOD_CULTURE_DXPOA_INF dataset (ASE 2.0)';
proc freq data=raw.blood_culture_dxpoa_inf;
tables blood_culture dxpoa_inf_primary blood_culture*dxpoa_inf_primary/missing;
run;

proc means n min max mean std data=raw.blood_culture_dxpoa_inf;
var bcx_drawn_day;
run;

	data ck;
	set raw.Blood_culture_dxpoa_inf;
	where (blood_culture=0 and dxpoa_inf_primary=1) | (blood_culture=1 and bcx_drawn_day ge 0);
	run;

