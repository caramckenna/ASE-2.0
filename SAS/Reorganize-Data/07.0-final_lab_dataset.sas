/*****************************************************************************
Program:		07.0-final_lab_dataset

DATE:   		9/18/25

Created by:		Christina Chan

Purpose:  		Create standardized input LABORATORY dataset for EHR Sepsis Algorithm

		 		 NOTE:  This table should include one row for each day that specific lab measures were taken

Input datasets:  
				edw.Labsdly_allmgb_2021_2023
				raw.basic:


Output Datasets:	
				raw.laboratory

****************************************************************************************************************/



*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';

*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';



*(1) Limit to variables of interest from BASIC;

			proc sql;
			create table basic_abbrev as
			select adm_id, 
					patientId,
					admission_date, 
					admit_date_hosp, 
					discharge_date,
					hospital_id,
					year
					from raw.basic; 
			quit;

/******************************************************************/
/** (2) Pull in DAILY dataset and get LAB variables of interest;
/***************************************************8**************/

/*** EDW Labs dataset (single allMGB dataset with vbls of interest) **/
data labs;
set edw.Labsdly_allmgb_2021_2023;
run;
	



/******************/


	*limit to vbls of interest;
	proc sql;
	create table labs2 as
	select distinct adm_id,
			patientID,
			admission_date label='admit date utc',  /* this version is in UTC format */
			specimenTakenDt as date label='lab date utc',
			(specimenTakenDt-admission_date)+1 as lab_day label= 'lab day utc',
			minCreat, maxCreat,
			minEGFR, maxEGFR,
			minTBILI, maxTBILI,
			minPLT, maxPLT,
			minLAC, maxLAC
	from labs;
	quit;



/*****/

	*(3)  MERGE DAILYLABS to BASIC;
			proc sort data=labs2;
				by adm_id date;
			run;

			proc sort data=basic_abbrev;
				by adm_id;
			run;

		/***(4a) LABS for ASE 2.0   *******/
		/**  For Comm-Onset infection, baseline lab values are defined as the best values during hospitalization.  
		     For Hosp-Onset infection, baseline lab values are defined as the best values in the two days prior to infection onset.  
			==>  Want values that fall b/w admission-1 and discharge:  Will limit in Organ Dysfunction program **/


			proc sql;
				create table final_labs_test as
				select  a.*, 
						b.*
				from basic_abbrev as a LEFT JOIN labs2 as b
				on (a.adm_id = b.adm_id) & (a.admission_date-2 <= b.date <= a.discharge_date);
			quit;


						*Dedup;
						proc sql;
						create table final_labs_test2 as 
						select distinct *
						from final_labs_test2;
						quit;

					proc sort data=final_labs_test2;
						by adm_id patientid admission_date discharge_date date;
					run;


/************************************************/
/*(7) SAVE TO PERMANENT DATASET ****/


data raw.laboratory;
set final_labs_test2;
run;





/*********************************************************************************************/
/*** FINAL QC ********************************************************************************/



proc means n nmiss min median max mean std data=raw.laboratory;
var minCreat maxCreat
			minEGFR maxEGFR
			minTBILI maxTBILI
			minPLT maxPLT
			minLAC maxLAC;
run ;


proc sort;
by year;

	proc means n nmiss min median max mean std data=raw.laboratory;
	var minCreat maxCreat
				minEGFR maxEGFR
				minTBILI maxTBILI
				minPLT maxPLT
				minLAC maxLAC;
	by year;
	run ;
