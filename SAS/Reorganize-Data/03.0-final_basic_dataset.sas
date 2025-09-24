
/******************************************************************************************************
Program:		03.0-final_basic_dataset

Purpose:  		Create standardized BASIC dataset for EHR Sepsis Algorithm
				[This is all inpatient encounters who had an antimicrobial prescribed during hospitalization, along with demographic characteristics]

Created by:		Christina Chan 

DATE: 			9/18/25

Input datasets:
					raw.encounters;
					derived.Pop_daily_allmgb_2021_2023

Output dataset:		final.basic

DATA SPECS for BASIC dataset:

NOTE:   one row for each unique encounter with patient demographics

********************************************************************************************************/

*v6.3 (EDW data refresh 2024);;
libname edw 'xx';
libname derived 'yy';


libname tmp 'xx\Reorganize Data v6.3\Tmp';
libname raw 'xx\Reorganize Data v6.3\Output';




/*************************************************/
/** (1)  DAILY DATASET (for comfort care variable)  **/
/*************************************************/

/*** EDW daily dataset (create single allMGB dataset with vbls of interest) **/
	**EDW_DAILY: Recall:  merge to ENCOUNTERS dataset, using EventDate variable;
  


	*(1) Macro to pull in & ICUalgo & Comfort Care variable from  POP_DAILY Datasets;

				proc sql;
				create table daily_allmgb as
				select distinct adm_id, patientID,
						admission_date_time, 
						discharge_date_time, 
						datepart(admission_date_time) as admission_date 	format mmddyy10. label='admitDT',
						datepart(discharge_date_time) as discharge_date 	format mmddyy10. label='dischargeDT',
						eventDate 						 as date format mmddyy10. label='eventDate',
						ICUalgo,

						comfortcare as comfort_care
				from derived.Pop_daily_allmgb_2021_2023;
				quit;


	*(4) Dedup (since daily-records from different hospitals are combined,there may be overlap);
				proc sql;
				create table daily_allmgb2 as
				select distinct *
				from daily_allmgb ;
				quit;

				*created ADJUSTED hospital_date (relative hosp_day (EST tx) added onto admitdate ;
				data daily_allmgb3;
				set daily_allmgb2;
				hosp_day= (date-admission_date)+1 ;  
				hospDT=(admission_date + hosp_day)-1;

				label hosp_day='eventDate relative to admission';
				label hospDT='eventDate';

				format hospDT MMDDYY10.;
				run;

					proc sort data=daily_allmgb3;
					by patientID  admission_date discharge_date date;
					run;

				



/*****************************/
/** (2) POP EPISODE  DATASET **/
/*****************************/


	/* Limit to variables of interest from ENCOUNTERS dataset;

			NOTE1: these are inpatient encounters from POP_EPISODE dataset in which antimicrobial was admin;
			NOTE2: STill need to add ICU_ADMIT_DATE, ICU_LOS (will add from separate ICU dataset)    **/

			proc sql;
			create table episode as
			select  adm_id, 
					patientID,
					admit_date_hosp,   /*use for ASE 1.0 */
					admit_date_ed,
					admission_date,
					discharge_date,
					year(admission_date) as year,
					admitLocation, dischargeLocation,
					substr(dischargeLocation,1,3) as hospital_id ,
					age,
					dob,
					deathDTS_derived,
					datepart(deathDTS_derived) as date_of_death format mmddyy10. label='deathDT, based on deathDTS_derived',
					gender as gender_txt,raceGroup, 
					discharge_dispo ,   dd_group
			from raw.encounters;
			quit;





				*LImit to smaller subset;
					proc sql;
					create table episode2 as
					select distinct adm_id, 
							patientID,
							admit_date_hosp,   /*use for ASE 1.0 */
							admit_date_ed,
							admission_date,
							discharge_date,hospital_id,
							admitLocation, dischargeLocation
							 
					from episode;
					quit;

							proc sort data=episode2; 
							by adm_id;
							run;

		  	  *Add Hospital Day variabe: create DAILY dataset, comprised of 1 row for each hospital day bw admit & discharge;
					data episode_dly (keep=adm_id patientID admission_date discharge_date hosp_dt hospital_id  admitLocation dischargeLocation);
						  _min = 1e9;
						  _max = -1e9;

						  * dow loop;

						  array dates (0:100000) _temporary_;

						  do until (last.adm_id);
						    set episode2;
						    by adm_id;

						    do hosp_dt = admission_date to discharge_date;
						      dates(hosp_dt) = 1;
						    end;

						    _min = min (_min, admission_date);
						    _max = max (_max, discharge_date);
						  end;

						  * output loop;

						  do hosp_dt = _min to _max;
						    if dates(hosp_dt) then output;
						  end;

						  call missing(of dates(*));

						  format hosp_dt mmddyy10.;
					run;

/***************************************************************/
/**(3)   ADD COMFORTCARE & ICU data TO POPULATION DATASETS    **/
/***************************************************************/

	/********************/
	/**  COMFORTCARE   **/
	/********************/

		*Merge in Comfort Care variable from Daily dataset;
			proc sql;
			create table comfcare_daily as 

			select a.*,
					b.comfort_care
		 
			from  episode_dly as a LEFT JOIN daily_allmgb3 as b
			on a.patientID=b.patientID and a.hosp_dt= b.hospDT;
			quit;


		*DE-DEDUP  (Recall:  since we are combining daily-level data from different hospitals, there may be duplicate dates for
						 patients who recieve comfort care in 2 diff locations on a single day);
			proc sql;
			create table comfcare_daily2 as
			select distinct *
			from comfcare_daily;
			quit;


		*CREATE DAY VARIABLES FOR COMFORT CARE ;
			proc sql;
			create table comfcare_daily3 as
			select 	 *, 
					max(comfort_care) as comfort_care_enc,
					(case when comfort_care=1 then hosp_dt end) as comfort_care_dt format mmddyy10.,
					(case when calculated comfort_care_dt ne . then min(calculated comfort_care_dt) end) as comfortcare_mindate format mmddyy10., 
					sum(comfort_care) as n_days_comfortcare
			from comfcare_daily2
			group by adm_id
			order by adm_id;
			quit;

			
		*LIMIT TO RECORDS WITH COMFORT_CARE=1 & create sequence/count variable;
			data comfcare_daily4;
			set comfcare_daily3;
			where comfort_care=1;
			run;


		*CONVERT FROM LONG TO WIDE (One encounter per record), CREATING UP TO 7 DIFF FIELDS FOR ComfortCare_date*/
			* RESHAPE;
				proc sort data=comfcare_daily4;
				by adm_id comfort_care_dt;
				run;

					data comfcare_daily4_wide;
						array ccd(7) comfortcare_dt1-comfortcare_dt7 ;
						format comfortcare_dt1-comfortcare_dt7 mmddyy10. ;

				
						do i=1 to 7 until (last.adm_id);
							set comfcare_daily4;
							by adm_id;

							ccd{i} = comfort_care_dt;

							if last.adm_id then output;
						end;
					
						drop I;
					run;


			*FINAL Episode-level dataset of all inpatient encounters with comfort care;
			*Limit to variables of interest;
				proc sql;
				create table comfcare_enc 
				as select distinct adm_id,
							patientID,
							admission_date,
							discharge_date, hospital_id,
							admitLocation,dischargeLocation,
							
							comfort_care_enc,
							comfortcare_mindate,
							n_days_comfortcare,
							comfortcare_dt1,comfortcare_dt2, comfortcare_dt3,
							comfortcare_dt4, comfortcare_dt5, comfortcare_dt6, comfortcare_dt7
				from comfcare_daily4_wide;
				quit;


			*Merge COMFCARE_ENC to entire Episode-level dataset;

				proc sql;
				create table comfcare_enc2 as
				select 	a.*, 
						b.comfort_care_enc,
						b.n_days_comfortcare,
						b.comfortcare_mindate,
						b.comfortcare_dt1,
						b.comfortcare_dt2,
						b.comfortcare_dt3,
						b.comfortcare_dt4,
						b.comfortcare_dt5,
						b.comfortcare_dt5,
						b.comfortcare_dt6,
						b.comfortcare_dt7
				from episode as a LEFT JOIN comfcare_enc as b
				on a.adm_id=b.adm_id  ;
				quit;


/***********************************************
**  ICU  VARIABLES	   
	want:  			-icuAlgo as icu_enc,
					-n_icu_days as icu_los, 
					-first_icu_date
***********************************************/

		*Merge in ICU variable from Daily dataset;
			proc sql;
			create table icu_daily as 

			select  a.*,
					b.ICUalgo
		 
			from  episode_dly as a LEFT JOIN daily_allmgb3 as b
			on a.patientID=b.patientID and a.hosp_dt= b.hospDT;
			quit;



		*DE-DEDUP  (Recall:  since we are combining daily-level data from different hospitals, there may be duplicate dates for
						 patients who recieve comfort care in 2 diff locations on a single day);
			proc sql;
			create table icu_daily2 as
			select distinct *
			from icu_daily;
			quit;


		*CREATE DAY VARIABLES FOR ICUalgo ;
			proc sql;
			create table icu_daily3 as
			select 	 *, 
					max(ICUalgo) as icu_enc,
					(case when ICUalgo=1 then hosp_dt end) as icu_dt format mmddyy10.,
					(case when calculated icu_dt ne . then min(calculated icu_dt) end) as icu_mindate format mmddyy10., 
					sum(ICUalgo) as n_days_icu
			from icu_daily2
			group by adm_id
			order by adm_id;
			quit;

			
		*LIMIT TO RECORDS WITH ICUalgo=1 & create sequence/count variable;
			data icu_daily4;
			set icu_daily3;
			where ICUalgo=1;
			run;


		*CONVERT FROM LONG TO WIDE (One encounter per record), CREATING UP TO 309 DIFF FIELDS FOR ICU_date*/
			* RESHAPE;
				proc sort data=icu_daily4;
				by adm_id icu_dt;
				run;

					data icu_daily4_wide;
						array icu(309) icu_dt1-icu_dt309 ;
						format icu_dt1-icu_dt309 mmddyy10. ;

				
						do i=1 to 309 until (last.adm_id);
							set icu_daily4;
							by adm_id;

							icu{i} = icu_dt;

							if last.adm_id then output;
						end;
					
						drop I;
					run;

					*save icu_daily4_wide to TMP library (for future reference, in case want to see encounters with 100+ days in ICU);
					data tmp.icu_daily4_wide;
					set icu_daily4_wide;
					run;


			*FINAL Episode-level dataset of all inpatient encounters with icu
			*Limit to variables of interest (Just keep the first 20 ICU dates...);
				proc sql;
				create table icu_enc 
				as select distinct adm_id,
							patientID,
							admission_date,
							discharge_date, 
							hospital_id,
							admitLocation,
							dischargeLocation,
							ICUalgo,
							icu_enc,
							icu_mindate, 
							n_days_icu,
						
							icu_dt1,
							icu_dt2,
							icu_dt3,
							icu_dt4, icu_dt5, icu_dt6, icu_dt7, icu_dt8, icu_dt9, icu_dt10, 
							icu_dt11, icu_dt12, icu_dt13, icu_dt14, icu_dt15, icu_dt16, icu_dt17, icu_dt18,  icu_dt19, icu_dt20,
							icu_dt50, icu_dt100,  icu_dt200, icu_dt300
				from icu_daily4_wide;
				quit;

				data tmp.icu_enc_allmgb;
				set icu_enc;
				run;


			*Merge ICU_ENC to entire Episode-level dataset;

				proc sql;
				create table icu_enc_enc2 as
				select 	a.*, 

							b.ICUalgo,
							b.icu_enc,
							b.n_days_icu,
							b.icu_mindate, 
							b.icu_dt1,
							b.icu_dt2,
							b.icu_dt3,
							b.icu_dt4, b.icu_dt5, b.icu_dt6, b.icu_dt7, b.icu_dt8, b.icu_dt9, b.icu_dt10,  
							b.icu_dt50, b.icu_dt100,  b.icu_dt200, b.icu_dt300
				from episode as a LEFT JOIN icu_enc as b
				on a.adm_id=b.adm_id  ;
				quit;


/** END ICU ****/

		*Merge in ICU variables (enc-level);

			proc sql;
			create table comfcare_icu_enc as
			select a.*, 
					b.icuAlgo as icu_enc,
					b.n_days_icu as icu_los, 
					b.icu_mindate AS first_icu_date

			from comfcare_enc2 as a LEFT JOIN icu_enc_enc2 as b
			on a.patientID=b.patientID and a.admission_date=b.admission_date and a.discharge_date=b.discharge_date ;
			quit;


			*reset missing values to 0;
			data comfcare_icu_enc2;
			set comfcare_icu_enc;
			if comfort_care_enc=. then comfort_care_enc=0;
			if icu_enc=. then icu_enc=0;
			run;


/***********************************************************/
/** (4)   ADD FINAL RECODES 							  **/
/***********************************************************/

	data comfcare_icu_enc3;
	set comfcare_icu_enc2;
	rename discharge_dispo=discharge_dispo_orig;
	*rename raceGroup=race_text;
	run;

	
	*Add RECODES: Convert First_ICU_Date to icu_admitdate (Day of first admission to ICU (relative to admit date);
		data basic_penult;
		set comfcare_icu_enc3;
		format discharge_dispo race 12.;
		icu_admitdate=(first_icu_date - admission_date) + 1;
		label icu_admitdate='ICU admission date, relative to start of hospitalization for ASE 2.0)';

		icu_admitdate_orig=(first_icu_date - admit_date_hosp) + 1 ;
		label icu_admitdate_orig ='ICU admission date, relative to inpt admission for ASE 1.0)';

		*convert gender, race, dicharge_dispo into numeric format;
		if dd_group ne 'Exclude' then do;
			if dd_group='Acute care hospital' then discharge_dispo=2 ;	/*2= tx to another acute care facility*/
			if dd_Group='Dead' then discharge_dispo= 4; 				/*4= death*/
			if dd_group='Home' then discharge_dispo= 1; 				/*1= home */
			if dd_group='Hospice' then discharge_dispo=5; 				/*5= hospice ***/ 
			if dd_group in ('Other', 'Rehabilitation facility', 'Skilled nursing facility') then discharge_dispo=3; /*3=subacute facility */
		end;

		if gender_txt='Male' then gender=1;
		if gender_txt='Female' then gender=2;

		if raceGroup ne ' ' then do;
			if raceGroup ='White' then race=1;									/* 1=white*/
			if raceGroup ='Black' then race=2; 									/* 2=black*/
			if raceGroup in ('Asian', 'Pac Islander') then race=3; 				/* 3=asian*/
			if raceGroup ='Hisp/Latino' then race=4; 							/* 4=Hispanic*/
			if raceGroup in ('Am Indian', 'Other', 'Two or More') then race=5; 	/* 3=Other*/
		end;

		run;


		*Add AdmitSource variable from Pop_Episode;
		proc sql;
		create table basic_penult2 as
		select a.*, b.admitSource
		from basic_penult as a LEFT JOIN derived.Pop_episode_allmgb_2020_2024feb as b
		on a.adm_id=b.adm_id;
		quit;

/*******************************************/

	*Rearrange final order of vblsl;
		proc sql;
		create table basic_final as
		select 	adm_id,
				patientid, 
				year,
				admit_date_ed,
				admit_date_hosp,
				admission_date,
				discharge_date,
				admitSource,
				hospital_id,
				age as age_yrs, 
				dob,
				gender,
				gender_txt, 
				race,
				raceGroup,
				discharge_dispo_orig, discharge_dispo,
				dd_group,
				deathDTS_derived,
				date_of_death,
				icu_enc,
				icu_admitdate,
				icu_admitdate_orig,
				first_icu_date,
				icu_los,
				comfort_care_enc,
				n_days_comfortcare,
				comfortcare_mindate,
				comfortcare_dt1,
				comfortcare_dt2,
				comfortcare_dt3,
				comfortcare_dt4

		from basic_penult2;
		quit;

/******************************************************************************/
/*(5) Save to Perm dataset ***/


	data raw.basic;
	set basic_final;
	run;

/******************************************************************************/




