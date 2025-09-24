/*****************************************************************************
Program:		06.0-final_vitals_hotn_dataset

DATE:   		9/18/25

Created by:		Christina Chan

Purpose:  		Create standardized input VITALS dataset for EHR Sepsis Algorithm 

				STEPS:
				-Add Vitals data  on systolic blood pressure (SBP) and mean arterial pressure (MAP)
				-Add recode for VALID blood pressure values (exlude missing and values le 0)
				-Add flag to ID records with measures that qualify for hypotension (SBP <90 or MAP <65)

		 		 NOTE:  Final dataset includes one row for each unique date/time stamp that a measure was taken for Blood Pressure (Systolic/Diastolic).
				

Input datasets: 
					raw.basic
					derived.popepimap_121124
					edw.BP_allmgb_2021_2023_061725 

						NOTE: pre-processed BP input dataset has been limited to records that meet hypotension criteria  (to minimize file size/processing run times)
						will retain SAS code that flags these variables for future reference
					    Hypotension is defined as 2+ readings of systolic blood pressure <90 mmHg or mean arterial pressure <65 mmHg within 3 hours), 


Output Datasets:	derived.allmgb_vitalsbp_daily_all
					==>  raw.vitals_bp_hotn

					Final dataset is comprised of:
						Pop_episode data merged to vitals data 
						Then limit to BP measures taken during pt hospitalization (hour/minutes level)
						Then add recodes to ID all valid measures (excluded missing, zero and negative values)
						and add flag for records that meet criteria for HOTN

****************************************************************************************************************/



*Filepath for population datasets (population datasets - daily & encounter-level);
*v6.3 (EDW data refresh 2024);;
libname edw 'xx ';
libname derived 'yyy';

*libname for  (6/17/25);
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';


*(1)  Pull in BP dataset;


/**
		 edw.Bp_allmgb_2021_2023 data was constructed in R 
		 --> (merged raw blood pressure data with encounters data on patient ID and recordedDTS falling between admission-2 and discharge;
			NOTE:  this data has already  been limited to measures that meet HOTN criteria (to minimize file size)

*****/



*[6/18/25]:  ;
data bp;
set edw.Bp_allmgb_2021_2023  ;
run;


	*BP == Population_Vitals dataset;

	data pop_vitals;
	set bp ;
		recordedDT = datepart(recordedDTS) ;
		recordedTM = timepart(recordedDTS);
		hosp_day=(recordedDT-admission_date)+1;
		map=int(map);

	label map='Mean Arterial Pressure'
	format map best12. ;
	format recordedDT mmddyy10.;
	format recordedTM time8.;
	run;


/*******************************************************************************************************************************************************/
/**  HYPOTENSION DEFINITIONS (will be added in Organ Dysfunction program):
HOTN3:  Hypotension (SBP <90 or MAP <65) on two separate occasions within 3 hours of each other, within the +/-1 day infection window (intermediate)
********************************************************************************************************************************************************/
* MAP = DP + 1/3(SP – DP) ;


* Pull in Updated BP VITALS_ALL dataset 
*This is daily/hourly-level BP data, merged to population_episode dataset where recordedDT falls b/w (admission-90 days) and (discharge +2 days);


*Recode for Valid measures of SBP and MAP (exlude missing and negative values);
data pop_vitals2;
set pop_vitals ;
if bpSystolic ne . and bpSystolic gt 0 then sbp_valid=bpSystolic;
if map ne . and map gt 0 then map_valid=map;

label sbp_valid='Valid Systolic BP (excludes missing & neg values)';
label map_valid='Valid MAP (excludes missing & neg values)';

run;

	*Add recode for HOTN, based on valid values;
	data pop_vitals3;
	set pop_vitals2;
	if sbp_valid <90 or map_valid <65 then flag_hotn=1;
		else flag_hotn=0;
		label flag_hotn='Hypotension (SBP <90 or MAP <65)';
	run;
	



	/** SAVE TO FINAL DATASET   **/
		data raw.vitals_bp_hotn;
		set pop_vitals3;
		run;

