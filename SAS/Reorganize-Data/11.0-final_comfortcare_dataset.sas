/*****************************************************************************
Program:		11.0-final_comfortcare_dataset


DATE:   		11/16/21 - for allMGB 2015-2021

UPDATED:		9/22/25
Created by:		Christina Chan


Purpose:  Create standardized input datasets for EHR Sepsis Algorithm:  comfort care
			-daily-level dataset for each day during a patients hospitalization that they are on comfort care

			-FINAL COMFORT CARE dataset (daily-level)
				adm_id, patientID, year, admission_date, admit_date_hosp, discharge_date,
				hospital_id, day, comfortCare, n_days_comfortcare,
				comfortcare_dt, comfortcare_day



INPUT DATASETS:		raw.basic

OUTPUT DATASETS:	raw.comfortcare
****************************************************************************************************************/


*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';


*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';




*(1) pull in encounter-level data on comfort care from BASIC;
proc sql;
create table cc as 
select adm_id, patientID, year, admission_date,  admit_date_hosp,
		discharge_date,
		hospital_id,  
		comfort_care_enc, 
		n_days_comfortcare,
		comfortcare_dt1, comfortcare_dt2, comfortcare_dt3, comfortcare_dt4

from raw.basic
where comfort_care_enc=1; 
quit;


*(3) transform to daily-level (convert wide to long);


	data cc_long ;
		set cc ;
	
	format comfortcare_dt mmddyy10.;
	
	array a comfortcare_dt1 - comfortcare_dt4;
	
	do i=1 to dim(a);
		comfortcare_dt=a{i};
		output;
	end;

	drop i comfortcare_dt1 comfortcare_dt2 comfortcare_dt3 comfortcare_dt4;
	run;
				data cc_long2;
				set cc_long;
				comfortcare_day=(comfortcare_dt-admission_date)+1;
				if comfortcare_dt=. then delete;
				run;


/*****/


/*SAVE TO PERMANENT LIBRARY **/
data raw.comfortcare;
set cc_long2;
run;


proc freq;
tables comfort_care_enc hospital_id year  /missing;
run;

proc freq;
tables comfort_care_enc*(hospital_id year)  /missing;
run;

