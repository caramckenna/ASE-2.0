/******************************************************************************************************

Program:		05.0-final_blood_culture_dataset

DATE:   		8/19/20  - Create VERSION 4 to reflect changes made for 2015-2020 EDW data;
Updated:		12/04/24 - Update for ASE 2.1 
							==>>  BCX_DRAWN_DAY now reflects bc_collection date relative to first day in hospital (admission to ED or inpatient, whichever occurs first)
								  Previous versions of BCX_DRAWN_DAY reflect bc_collection date relative to admission as inpatient
				8/15/25 - Limit to all cultures that are collected between admission-1 and discharge (formerly admit-2)

Created by:		Christina Chan

Purpose:		Create Blood Culture dataset:
				NOTE:  This dataset is combined with DXPOA flag dataset in a separate program (SAS program: 09.0-final_blood_culture_dxpoa_infxn_dataset)

				STEPS:
				-Pull in raw.BASIC dataset 
				-Merge to Micro/Blood culture data (Daily-level);
				-Run QC - 

				Recall:  WE only want 3 variables for this dataset: 
					patient_id
					admission_id
					bcx_drawn_day -- based on blood culture collection date, relative to first day in hospital (admit to ED or inpatient, whichever is first)

INPUTS: 				
			raw.basic
			derived.Pop_bcx_2021_2023

OUTPUT:		raw.blood_culture
				-NOTE:  this dataset includes BCX_DRAWN_DAY	=='BloodCulture drawn day, relative to 1st day in hosp (admit to ED or inpatient, whichever is first)'
									==>> use for ASE 2.0



********************************************************************************************************/


*Filepath for population datasets (population datasets for allMGB EDW - daily & encounter-level);
*v6.3 (EDW data refresh 2024);;
libname edw 'xx ';
libname derived 'yyy';

*libname for  (6/17/25);
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';

*(1) pull in datasets (BASIC for BWH 2015-2022);

	/**[12/04/24]:  RECALL:

			For ASE 2.1, use Basic dataset derived from Population Episode (2023).
				In population episode dataset, admission_date variable is defined as:
					     -admit_date_hosp = datepart(hospitalAdmitDTS) 
						 -admit_date_ed = datepart(edArrivalDTS) 	   
						 -admission_date= min(admit_date_hosp, admit_date_ed)  

	*******************************************************/

*(1)  Pull in Basic dataset;
	*Limit to variables of interest from BASIC;

	proc sql;
	create table basic_abbrev as
	select adm_id, 
			patientId,
			admission_date,  
			admit_date_ed,
			admit_date_hosp, 
			discharge_date,
			hospital_id,
			year
			from raw.basic; 
	quit;




*(2)  Pull in Blood Culture dataset;
	data bloodcx;
	set derived.Pop_bcx_2021_2023_061625;
	drop bcxCollday;    /*will recalculate this below **/
	run;

	*dedup/simplify;
	proc sql;
	create table bloodcx2 as 
	select distinct adm_id,
					patientid,
					admission_date_time,
					bcxCollDT as coll_date, 
					bcx_match_type,
					1 as cx_blood
	from bloodcx;
	quit;


/*************************************/


/*(5) merge BLOOD to BASIC */
/*Limit to blood culture draws betweeen admission-1 and discharge*/

	proc sql;
	create table basic_blood as
	select 	distinct a.*,
			b.patientID as ptid_bc,
			b.coll_date,
			b.cx_blood

	from basic_abbrev as a LEFT JOIN bloodcx2 as b
	on (a.adm_id=b.adm_id) and (a.admission_date-1 <= b.coll_date <= a.discharge_date)  

	;
	quit;

	* Create new bcx_drawn_day variables;
	data basic_blood2;
	set basic_blood;
	bcx_drawn_day=(coll_date-admission_date)+1;
	run;


/** LIMIT TO VARIABLES OF INTEREST ******/

proc sql;
create table basic_blood3 as 
select distinct adm_id, patientId, hospital_id, 
				admission_date, admit_date_ed, 
				admit_date_hosp, coll_date, bcx_drawn_day
from basic_blood2
where cx_blood=1;
quit;


/*** SAVE to perm dataset**/
data raw.blood_culture;
set basic_blood3;
run;


