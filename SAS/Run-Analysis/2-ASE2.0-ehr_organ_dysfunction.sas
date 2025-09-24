*****************************************************************************************
* PROGRAM:  2 ASE2.0 - ehr_organ_dysfunction_final

* PURPOSE: Creates organ dysfunction variables used in various sepsis definitions        *
*						 
* BY:	  Christina Chan

* DATE:   9/15/25    FINAL version of SAS code, cross-referenced against Cara McKenna R scripts		


*  INPUT DATASETS:
							raw.basic
							raw.blood_culture_dxpoa_inf 
							raw.diagnosis, 
							raw.diagnosis_flag 
							raw.laboratory, 
							raw.vitals_bp_hotn 
							raw.medication, 
							raw.oxysupp_dly
							sepsis.ehr_infection

*  OUTPUT DATASETS:
							sepsis.ehr_organ_dysfunction

****************************************************************************************/



*libname for FINAL;
libname tmp   'Z:\XXX\Reorganize Data v6.3\Tmp';
libname raw   'Z:\XXX\Reorganize Data v6.3\Output';
libname sepsis 'Z:\XXX\Run analysis\working datasets';



/* The names of the datasets and been pre-filled below.  Make changes as necessary 
    to match the names of datasets you've placed in the Raw folder */

*******************************************************/


*MODIFY DATASET NAMES;

    /* infection dataset */
    %let infection =  Ehr_infection  	;			
                     
    %let bloodculture = Blood_culture_dxpoa_inf  ;            


*FIXED DATASETS;
    /* Basic dataset name */
    %let basic = basic;

    /* Medication dataset name */
    %let medication = medications    ;  

    /* Diagnosis dataset name */
    %let diagnosis = diagnosis;

    /* Laboratory dataset name */
    %let laboratory = laboratory;

    /* Vitals dataset name */
    %let vitals =  vitals_bp_hotn;				

    /* Oxysupp dataset name [includes ALL oxy devices throughout the day -- hourly/minute measures*/
     %let oxysupp = oxysupp_dly;						  






/************************************************************************************/
/* End of user inputs     									                       */
/************************************************************************************/




options nocenter pageno = 1 mprint macrogen;



* CREATE BASIC DATASET (== all inpatient encounters that received an antibiotic b/w admission & discharge);

data basic_fnl;
    set raw.basic;
    discharge_day=(discharge_date-admission_date)+1;
run;


/***********************************************************/

/** BLOOD CULTURE ****/
/** BLOOD CULTURE ****/
/** BLOOD CULTURE ****/


*(1a) Pull in BLOOD_CULTURE_DXPOA_INF dataset;
			 /*This is a subset of patients who received antibiotics, and either had a blood culture -AND/OR- icd10 POA code for infection (principal dx code).
				Infection_anchor_date has been adjusted to account for presence of principal dx icd10 POA infection code (with/out BC).
				* NOTE: THIS DATASET uses INFXN_ANCHOR_DAY , instead of BCX_DRAWN_DAY *****/

		*Limit to blood cultures drawn between admission-1 and discharge;
			data bloodculture;
			set  raw.&bloodculture; 
			where (blood_culture=0 and dxpoa_inf_primary=1) | (blood_culture=1 and bcx_drawn_day ge 0);
			infxn_anchorDT=(admission_date+infxn_anchor_day)-1;
			format infxn_anchorDT mmddyy10.;
			run;





*(1b) Pull in EHR_INFECTION dataset --> want Infxn_onset_day;

			data infection;
			set sepsis.&infection; 
			run;

/****************************************************************************************/
/* Initiation of a new vasopressor within +/- 1 days of Infxn_onset_day 				*/
/****************************************************************************************/

data medication;
set raw.&medication;
where day ge 0;
run;

/* Retrieve vasopressor data from EDW Meds data */
/* NOTE:  all vasopressos must be IV  (all pressors in meds input dataset are IV) **/

proc sql;
    create table vasopressor1 as
        select distinct a.adm_id,
                        a.patientID,
                        b.admission_date, 
						b.discharge_date,
                        upcase(a.Med) as Med,
                        a.medication_date,
                        a.Day
        from medication a,
             basic_fnl b
        where upcase(a.med) IN("NOREPINEPHRINE", "DOPAMINE", "EPINEPHRINE", "PHENYLEPHRINE",
                               "VASOPRESSIN") and
              a.adm_id = b.adm_id and a.patientID = b.patientID and
              a.medication_date <= b.Discharge_date
        order by adm_id, patientID, med, Day;
quit;




/* Determine if vasopressor is new */
/* NEW for ASE 2.0: different vasopressor mednames are used interchangeably for consecutive days */
/* Will separate vasopressor_new = 1 into later data step */

proc sort data=vasopressor1;
by adm_id patientID day;
run;


	data vasopressor2 (drop = diff);
	    set vasopressor1;
	    by adm_id patientID day;
	    diff = ifn(first.adm_id = 0, day - lag(Day), .);

	    if diff ^= 1 then vasopressor_new = 1;
	    else vasopressor_new = 0;

	run;


/*Add step for selecting new vasopressor */
data vasopressor3;
    set vasopressor2;
    if vasopressor_new = 1;
run;


/* Select cases with new vasopressor in +/- 1 day window for Infection Onset Date*/
proc sql;
    create table vasopressor4 as
        select distinct a.*,
                        b.infxn_onset_day 
        from vasopressor3 a,
             infection  b
        where a.adm_id = b.adm_id and a.patientID = b.patientID and
              -1 <= (a.Day - b.infxn_onset_day ) <= 1;
quit;


*Add date variable for Pressor initiation;
proc sql;
    create table vasopressor_fnl as
        select adm_id,
               patientID, admission_date,  discharge_date,
               infxn_onset_day ,
               min(medication_date) as vasopressor_min_date format mmddyy10.,
               min(Day) as vasopressor_min_day,
               max(vasopressor_new) as vasopressor_new
        from vasopressor4
        group by adm_id, patientID,  infxn_onset_day ;
quit;



/*** ADD HYPOTENSION DEFINITION   ******************************************************************************************************************************/
/** VITALS:  HOTN 
  Within each episode:
		-identify instances in which there are two separate readings of HOTN within a 3 hr period
		-flag the 2nd/max recordedDTTM ==>  this is HOTN_DAY
		-check if HOTN_DAY falls within +/- 1 day of infection onset day:
****************************************************************************************************************************************************************/


*(1) Pull in HOTN/VITALS dataset & merge to BASIC data;


/* Limit clinical data to records from admission_day-1 (hosp day 0) through discharge **/
data vitals;
set raw.&vitals ;
where hosp_day ge 0;
run;

	proc sql;
	    create table basic_vitals1 as
	        select distinct a.adm_id,
	                        a.patientID,
							a.admission_date,
							a.discharge_date,   
							b.hosp_day as recorded_day,
							b.recordedDTS,
							b.recordedDT,
							b.recordedTM,
							b.flag_hotn

	        from basic_fnl a,
	             vitals  b
	        where a.adm_id = b.adm_id and a.patientID = b.patientID;
	quit;


*(2)  Limit to measures where flag_hotn=1;
	data basic_vitals2;
	set basic_vitals1;
	where flag_hotn=1;
	run;

/*(3) Merge BASIC_VITALS1 data to Infection Data 
		/**==>>  this is a dataset of all HOTN measures that occurred during encounter (b/w admission & DC) **/

		/* Limit to Cases with vitals data within -3/+2 days of Infection Onset Date;
		  *NOTE_1: Even though infection window is +/- 1 day, will want to look 2 days beyond that window 
				   WHY? (1) to ensure HOTN new "new" and (2) since HOTN-OD requires 2 measures, make sure to include cases where first measure might fall outside the +/- 1 day window...
		  *NOTE_2: Will limit to records that fall within +/- 1 day infection window later**/

			proc sql;
			    create table bc_vitals1 as
			        select distinct a.adm_id,
			                        a.patientID,
									a.dxpoa_inf_primary,
									a.bcx_drawn_day,
									a.infxn_anchor_day,
									a.QAD_first,
									a.infxn_onsetdT,
									a.infxn_onset_day,
									b.recorded_day,
									b.recordedDTS,
									b.recordedDT,
									b.recordedTM,
									b.flag_hotn

			        from infection  a,
			             basic_vitals2  b
			        where a.adm_id = b.adm_id and a.patientID = b.patientID and
			              -3 <= (b.recordedDT - a.infxn_onsetDT ) <= 2;
			quit;



*(4) Identify episodes where there are 2+ readings of HOTN within 3 hrs; 

			* Add recode for HYPOTENSION indicator;
			**HYPOTENSION (at least one reading of SBP <90 or MAP < 65), without vasopressors or other eSOFA during infection window;
			**EXCLUDE  SBP values = [missing] or =<0 ; 

			*(4a) Create summary-level vbl -- calculate total number of hotn_flags during inf pd;
				proc sql;
				create table bc_vitals2 as
				select 	*, sum(flag_hotn) as nflag_hotn
				from bc_vitals1
				group by adm_id, infxn_onset_day 
				order by adm_id, infxn_onset_day ;
				quit;

					proc sort data = bc_vitals2;
					by adm_id  infxn_onset_day  recordedDTS;
					run;

			
			*(4b) LIMIT TO VBLS OF INTEREST (adm_id, infxn_anchor_day, recorded_day, recordeddts, flag_hotn, nflag_hotn) - WHERE HOTN_FLAG=1;

				proc sql;
				create table bc_vitals3 as
				select distinct adm_id, 
						patientID, 
						infxn_onset_day , 
						infxn_onsetDT , 
						recorded_day, 
						recordedDTS, 
						recordedDT, 
						recordedTM, 
						flag_hotn ,
						nflag_hotn
				from bc_vitals2  where flag_hotn=1;
				quit;

	  /**** ID HOTN episodes with (2+ HOTN measures occurring within 3 HRS) *****/
			*(4c) Create infID to demarcate separate infection periods;
				data bc_vitals4;
				set bc_vitals3;
				format infID $14.;

				infID=compress(adm_id||"_"||infxn_onset_day);				
				label infID="Infection period: adm_id + infxn_onset_day";	
				run;

			*(4d) Select distinct;
				proc sql;
				create table bc_vitals4a as
				select distinct *
				from bc_vitals4;
				quit;

			*(4e) Sort data by adm_id, infxn_anchorDT,  and recordedDTS ;
				proc sort data= bc_vitals4a;
				by infID recordedDTS;
				run;

			*(4f) Create Lag variable (backwards lag on recordedDTS) & use to calculate time difference b/w previous BP Measure;
				data bc_vitals5;
				set bc_vitals4a;
				by infID;
				lagbk_recordedDTS = lag(recordedDTS);

				if first.infID then lagbk_recordedDTS = . ;
				format lagbk_recordedDTS B8601DZ35.;

				diff_in_mins_bk =intck("min", lagbk_recordedDTS,recordedDTS );
				diff_in_hours_bk =intck("hour", lagbk_recordedDTS, recordedDTS );
				run;

/*(5)  Create flags for Infection episodes that meet criteria for  HOTN3 definition:
	HOTN3:  New Hypotension (SBP <90 or MAP <65) on TWO SEPARATE OCCASIONS WITHIN 3 HOURS OF EACH OTHER, within the +/-1 day infection window  ****/

				DATA hotn;
				set bc_vitals5;
					if nflag_hotn=1 then do;
						hotn3=0;
					end;
					if nflag_hotn ge 2 and diff_in_mins_bk= . then do;
							hotn3=0;
					end;
					else if diff_in_mins_bk ne . then do;
							if diff_in_mins_bk le 180 then hotn3=1; 
							if (0 le diff_in_mins_bk) and(diff_in_mins_bk le 180) then hotn3=1;   
							else hotn3=0;
					end;
				run;

			  *Set HOTN_DAY == recorded_day for instances where interval b/w 2 HOTN readings is <180 mins;
				data hotn2;
				set hotn;
				if hotn3=1 then hotn3_day=recorded_day;
				where hotn3=1 ;
				run;


				*Limit to records that fall within +/- 1 day of infection window;
				** widen window to (-2/+1 day) so can ID days that look for cases of *NEW*  hotn within -1 day of infxn_anchor_day; 
				** +/-1 day window is centered around INFXN_ONSET_DAY (no longer infxn_anchor_day);
					data hotn3;
					set hotn2 ;
					where  infxn_onset_day-2  le hotn3_day le infxn_onset_day+1;     
					run;

					*Simplify #1;
					proc sql;
					create table hotn4 as
					select distinct adm_id, infID,
					patientID, infxn_onset_day, infxn_onsetDT,
					recordedDTS, hotn3, hotn3_day
					from hotn3;
					quit;

						*Simplify #2 (remove recordedDTS);
						proc sql;
						create table hotn5 as
						select distinct adm_id, infID,
						patientID, infxn_onset_day, infxn_onsetDT,
						/*recordedDTS,*/ hotn3, hotn3_day
						from hotn4;
						quit;




/*(6) Identify *NEW* cases of hypotension (ie, no instances of  HOTN(2+ hotn measures within 3 hrs) in previous calendar day) **/
	/*STEPS TO ID hotn measures to exclude (ie, hotn in previous calendar day): 
			-create limited dataset (only keep adm_id, hotn_day)
			-create indicator variable to ID new cases (no hotn in previous day)
			-then incorporate pressor data- create flags to ID (a) pressors occuring in previous calendar day,  (b) escalating CVD symptoms on consecutive days  (ie, hotn -->  pressors)
			-then merge flags back to hotn5;
			-and use indicator to delete rows where NEW=0 (or keep rows where NEW=1)
*************************************/

	proc sort data=hotn5;
	by adm_id infID hotn3_day;
	run;

		/*I. Create dataset of NEW hotn days*/
		proc sql;
		create table hotn5_newid as
		select distinct adm_id, hotn3_day
		from hotn5;
		quit;

			data hotn5_newid2;
			  set hotn5_newid;
			  by adm_id;

			  /* Create a lagged date variable */
			  lag_date = lag(hotn3_day);

			  /* Reset lagged date for the first observation of each patient */
			  if first.adm_id then call missing(lag_date);

			  /* Calculate the difference in days */
			  if not missing(lag_date) then do;
			    difference = intck("days", lag_date, hotn3_day, "c");
			  end;

			  /* Identify new cases (difference ^= 1) */
			  if difference ^=1 then hotn_new=1;

			run;

			/*Limit to new cases only */
			data hotn5_newid3;
			set hotn5_newid2;
			drop lag_date difference;
			where hotn_new=1;
			run;

		/* Merge back to MAIN/INFECTION dataset, to get infection ONSET day and limit to NEW hotn records that fall within +/- 1 day */
			proc sql;
			create table hotn5_newid3a as
			select distinct a.adm_id, a.infID, a.patientID, a.infxn_onset_day, b.*
			from hotn5 as a  RIGHT JOIN hotn5_newid3 as b
			on a.adm_id= b.adm_id and a.hotn3_day=b.hotn3_day;
			quit;

				data hotn5_newid3b;
				set hotn5_newid3a;
				diff=infxn_onset_day-hotn3_day;   
				run;


				/*Limit to HOTN3_days that fall within +/- 1 day of infxn_onset_day;
				**THIS IS THE PENULTIMATE DATASET - final version unless there are pressors the following day....*/
					data hotn5_newid3c;
					set hotn5_newid3b;
					where diff in (-1, 0, 1);		
					run;

/*(7)  Identify cases with escalating CVD organ dysfunction   */
/*  NEED TO: Incorporate Pressor data into HOTN definitions to further limit:
	*To be counted as "new" hotn, there must be NO hotn -OR- pressors in the preceding calendar day;
	* For HO-ASE, cardiovascular OD's (HOTN/Pressors) must be new or escalating on consecutive days  (ie, hotn -->  pressors);
	* Calculate difference in days b/w Pressor and HOTN:  
			-DIFFDAYS_HOTN_PRESSOR=  1 indicates Pressors were admin 1 calendar day before HOTN3 [use to ID de-escalating CVD Org Dys, where pressor --> hotn]. Want to Exclude these.
			-DIFFDAYS_HOTN_PRESSOR= -1 indicates escalating cardiovascular OD (hotn -->  pressors)

     **USE VASOPRESSOR2 from pressor code -- pull in all days where a pressor was administered (from pressor consecutive days dataset)     ***/

	/**RECALL:
		HOTN5 dataset reflects ALL hypotension (new and old) 
	    HOTN5_NEWID3C dataset reflects NEW hotn cases that fall within +/- 1 day */

		data hotn5_newid3d;
		set hotn5_newid3c;
		drop diff;
		run;

				*merge NEW_HOTN data to ALL_HOTN (hotn5);
				proc sql;
				create table hotn5_all as
				select  distinct a.*, 
						b.hotn_new
				from hotn5   as a LEFT JOIN hotn5_newid3d as b
				on a.adm_id=b.adm_id and a.infxn_onset_day=b.infxn_onset_day and a.hotn3_day=b.hotn3_day;
				quit;

					proc sql;
					create table hotn5_pressor as
					select  distinct a.*, 
							b.day as pressor_day,
							b.vasopressor_new
					from hotn5_all as a LEFT JOIN vasopressor2  as b
					on a.adm_id=b.adm_id ;
					quit;

					*calculate difference in days b/w pressors & hotn;
					data hotn5_pressor1;
					set hotn5_pressor;
					diffdays_hotn_pressor=(pressor_day- hotn3_day);
					run;

						proc sql;
						create table hotn5_pressor2 as 
						select *,
						case when diffdays_hotn_pressor = -1 then 1 else 0  end as  hotn_pressors_prior label='HOTN3 flag: HOTN3 with pressors administered on prior calendar day (REMOVE ME)',
						case when diffdays_hotn_pressor =  1 then 1 else 0  end as  hotn_pressors_esc   label='HOTN3 flag: escalating cardiovasc OD (HOTN3 on this day, followed by Pressors next day)'
						from hotn5_pressor1;
						quit;

							*Want to ID HOTN_new day that is associated with de-escalation 
							(ie, pressors on previous day);
							proc sql;
							create table hotn5_pressor3 as
							select *, 
							max(hotn_pressors_prior) as hotn_pressors_prior_day,
							max(hotn_pressors_esc) as hotn_pressors_esc_day
							from hotn5_pressor2
							group by infID, hotn3_day
							order by infID, hotn3_day ;
							quit;

					*Remove all records of HOTN3_NEW that are associated with de-escalation from Pressors in prior day;
					data hotn5_pressor4;
					set hotn5_pressor3;
					if hotn_pressors_prior_day=1 then delete;
					run;
						/**Now, all the HOTN3_new records that remain, were either NEW and/or escalation ((Followed by Pressors on Day 2); */

					proc sql;
					create table hotn5_pressor5 as
					select distinct adm_id, infid,
							patientID, 
							infxn_onset_day,
							hotn3, hotn3_day, hotn_new,
							hotn_pressors_esc_day

					from hotn5_pressor4;
					quit;


/* (8)  CREATE FINAL DATASET**/

	/*Limit to records where hotn_new=1 -OR- od_hotnprssr_esc=1;
	 NOTE: All records  fall within +/-1 day of infxn_onset_day  **/ 

	data Hotn5_pressor6;
	set hotn5_pressor5 ; 
	where  hotn_new=1 ;   /*New Hypotension cases only) */
	run;


		*penltimate HOTN dataset;
		proc sql;
		create table hotn_penult as 
		select distinct adm_id, patientID, infxn_onset_day, hotn3, hotn3_day, hotn_new 
		from  Hotn5_pressor6 
		where hotn_new=1;
		quit;

			*Create final HOTN dataset (take min_od_day for each infxn_onset_day);
			proc sql;
			create table hotn_fnl as 
			select distinct adm_id, 
					patientID, 
					infxn_onset_day, 
					hotn3, 
					min(hotn3_day) as hotn3_minday
			from hotn_penult
			group by adm_id, patientID, infxn_onset_day
			order by adm_id, patientID, infxn_onset_day;
			quit;

                                                             
/*** END HYPOTENSION DEFINITION  ***************/
/*******************************************************************************/


/******* BEGIN  RESPIRATORY ORGAN DYSFUNCTION************************************/

/* INITIATION OF INVASIVE MECHANICAL VENTILATION & OTHER OXY SUPPLEMENTATION    *

		ASE 2.0 Respiratory OD: Initiation of mechanical ventilation (any duration) -OR-
								Initiation of non-invasive ventilation or high flow nasal cannula (for 2+ consecutive calendar days)

		NOTE: Patients with ICD-10 codes for obstructive sleep apnea (dx_osa=1) are excluded from meeting resp OD for non-invasive ventilation
			  unless they have also have icd10 codes for acute/ unspecified respiratory failure (dx_rf=1)
			  [NOTE: dx_osa was formerly, dx_s_apnea) 

			  Operationalized as:   
				o Create 2 types of resp_OD:   od_resp_mv & od_resp_niv  (where pt qualifies for od_resp if either od_resp-type=1)
				 	o if dx_osa=1  			 then od_resp_niv =0 (exclude from resp OD_NIV):
					o if dx_osa=1 & dx_rf=1  then od_resp_niv =1

		**********************************************/
        /***UPDATED  DEVICE MAPPINGS in EDW/ MGB 2022 --> updated with STZ mappings 05.21.25 & 07.09.25
                     1 Nasal cannula 
                     2 Simple mask  
                     3 Oxymizer   
                     4 Advanced mask 
                     5 High flow  
                     6 BIPAP   
                     7 Ventilator  
                     8 ECMO   
       **********************************************************************************************************************/


/**(1) PULL IN RAW OXYSUPP DATA  **/

/*Limit clinical data to records from admission_day-1 (hosp day 0) through discharge **/
data oxysupp;
set raw.&oxysupp;
where oxysupp_hospday ge 0;
run;


    proc sql;
        create table oxysupp_proc1 as
            select distinct a.adm_id,
                            a.PatientID,
                            b.admission_date, b.discharge_date,
                            a.oxysupp_hospdate as oxysupp_date, 
                            a.oxysupp_hospday  as oxysupp_day,
                            a.o2DeviceMappedn,
                            a.o2DeviceMapped,
                            (case when o2DeviceMappedn=7 then 1 end) as mechvent, 
                            (case when o2DeviceMappedn=6 then 1 end) as nippv label='BIPAP/ Non Invasive Pos Pressure Vent only', 
                            (case when o2DeviceMappedn=5 then 1 end) as hfnc  label='High Flow Nasal Cannula only' 
            from oxysupp a,
                 basic_fnl b

            where a.adm_id = b.adm_id and a.PatientID = b.PatientID and
                 ( b.admission_date-1 <= a.oxysupp_hospdate <= b.discharge_date)

            order by adm_id, PatientID, oxysupp_day;
    quit;

        *save to TMP folder for future reference;
        data tmp.oxysupp_proc1;
        set oxysupp_proc1;
        run;


/**(2)  CREATE WORKING DATASETS FOR OXYSUPP: Create separate datasets for each type of respiratory eSOFA **/

	*(2A) Mechvent only;
        data resp_mechvent;
        set oxysupp_proc1;
        where mechvent=1;
        run;

	*(2B) Non-Invasive Vent only:   Bipap/NIPPV, or HFNC;
		data resp_nivhfnc;
        set oxysupp_proc1;
		if (hfnc=1 or nippv=1) then niv_hfnc_=1;
        run;

		/* Incorporate icd10 codes for sleep apnea/respiratory failure:
		   NOTE: Patients with ICD-10 codes for obstructive sleep apnea are excluded from meeting resp OD
			     based on non-invasive ventilation, unless they have also have icd10 codes for acute/ unspecified respiratory failure ****/

		*Merge in icd10_dx_flags;
		proc sql;
		create table resp_nivhfnc2 as
		select a.*, b.dx_osa, b.dx_rf
		from resp_nivhfnc as a LEFT JOIN raw.Diagnosis_flag as b
		on a.adm_id=b.adm_id;
		quit;


		*If dx_osa=1 without resp failure, then exclude NIV only (HFNC remains intact);
		data resp_nivhfnc3;
		set resp_nivhfnc2;
			if niv_hfnc_=1 then do;
				if dx_osa=1 and dx_rf=0 then nippv_new=0;  *exclude from resp OD_NIV;
			else nippv_new=nippv ;
			end;
		drop niv_hfnc_;
		run;

		*Add recode for combined NIV/HFNC;
		data resp_nivhfnc4;
		set resp_nivhfnc3;
		niv_hfnc =max(nippv_new, hfnc);
		run;


	*(2C) Mechvent, Bipap/NIPPV, or HFNC;
		data resp_mv_nivhfnc;
        set resp_nivhfnc4 ;
		if (mechvent=1 or niv_hfnc=1) then mv_niv_hfnc=1;
        where mechvent=1 or niv_hfnc=1;
        run;


/*(3) For Resp OD: MECH VENT only**/
    /** Select cases without oxysupp/mechanical ventilation in previous day*/
    /*  Final version only contains records where OxySupp occurs within +/- 1 days of infxn_onset_day */

proc sort data=resp_mechvent;
by adm_id oxysupp_day;
run;

        data resp_mechvent1 ;
            set resp_mechvent;
            by adm_id PatientID;
            diff = ifn(first.PatientID = 0, oxysupp_day - lag(oxysupp_day), .);
            if diff ^= 1;
        run;

                proc sql;
                create table resp_mechvent2 as
                select distinct a.adm_id,
                                a.PatientID,
                                a.oxysupp_day,
                                a.mechvent,
                                a.nippv,
                                a.hfnc,
                                b.infxn_onset_day  
                from resp_mechvent1 a,
                     infection  b
                where a.adm_id = b.adm_id and a.patientID =b.patientID 
                      and (-1 <= a.oxysupp_day - b.infxn_onset_day)  and (a.oxysupp_day - b.infxn_onset_day <= 1);
                quit;


                        proc sql;
                            create table resp_mechvent_fnl as
                                select distinct a.adm_id,
                                                a.PatientID,
                                                a.infxn_onset_day,
                                                min(oxysupp_day) as mechvent_min_day,
                                                max(mechvent) as mechvent label="Mechvent only"

                                from resp_mechvent2 a
                                group by adm_id, PatientID, infxn_onset_day;
                        quit;


	
/*****************************************************************************************/

/*(4) For Resp OD2: NIV/ HFNC**/

/*STEPS for NIV_HFNC:   
	1. From long dataset, identify records that indicate start of a newly initiated oxysupp (ie, no oxysupp in prior calendar day);
	2. Create abbreviated version of newly initiated oxysupp dataset [AAA]
	3. Calculate n consecutive days (consecdays macro)
		-create abbreviated version
	4. Merge consec days to INFECTION dataset [ZZZ]--> Keep records where firstdate (of consec oxysupp) falls within +/- 1 day of infection window
	5. from ZZZ, limit to records where new oxysupp is initiated  
		-- use AAA dataset to ID which periods of consec days can be considered "newly initiated"
		-->  ie, where firstdate (from nivhfnc_merge)=oxysupp_date (from resp_nnivhfnc_init)
**********************************/

   	/** ID infection episodes that are associated with 2+ consec days of any of NIPPV/BIPAP or HFNC.. 		***/
	/**	 Add recode that identifies patients with 2+ measures of HFNC or NIPPV within 2 consecutive days 	***/
	/**	 ALSO -- Allow for escalation from NIV/HFNC on day to to MV on day 2  								***/

*(1) In the MV/NIV/HFNC dataset, create enc-level indicators of mechvent_enc (at least 1 day on Mech Vent);
	proc sql;
	create table Resp_mv_nivhfnc2 as
	select distinct adm_id, 
					admission_date, 
					discharge_date, 
					patientID, 
					oxysupp_date, 
					oxysupp_day, 
					mechvent, 
					niv_hfnc, 
					mv_niv_hfnc
	from resp_mv_nivhfnc    
	group by adm_id
	order by adm_id;
	quit;

	*(1a) merge infection_onset_day to RESP_MV_NIVHFNC2;
		*NOTE THIS MAY RESULT IN DUPLICATION OF OXYSUPP RECORDS IF there are 2+ infxn_onset_days per encounter ;
		*Example: mechvent on day 2 will match to infxn_onset_days (1,2,3);
			 proc sql;
			 create table Resp_mv_nivhfnc3  as
			 select distinct b.*, a.infxn_onsetDT, a.infxn_onset_day
			 from infection as a INNER JOIN Resp_mv_nivhfnc2 as b
			 on (a.adm_id=b.adm_id);
			 quit;

				proc sort data = Resp_mv_nivhfnc3 ;
				by adm_id  infxn_onset_day oxysupp_day;
				quit;

			/**** ==>>  Resp_mv_nivhfnc3 (merged w infxn_onset_day) will be used later [STEP 7] to create MASTER_OXYSUPP2:  

/*(2) starting with MAIN Resp_mv_nivhfnc2 dataset (not joined to INFECTION data), identify OXYSUPP_DAY that indicates start of a new initiation period */
			*Limit to records that indicate start of a new Initiation period (ie. no NIV/HFNC or MV, in previous calendar day);

			proc sort data=Resp_mv_nivhfnc2;
			by adm_id  oxysupp_day;
			quit;

		  
	       data Resp_mv_nivhfnc2_init  ;
           set Resp_mv_nivhfnc2;
              by adm_id oxysupp_day;
              diff = ifn(first.adm_id = 0, oxysupp_day - lag(oxysupp_day), .);
              if diff ^= 1;
            run;

				**Create abbreviated version;
				proc sql;
				create table Resp_mv_nivhfnc2_init2 as
				select distinct adm_id, patientID, oxysupp_date, oxysupp_day,  mechvent, niv_hfnc, 
						oxysupp_day as oxysupp_init_day label='Oxy Supp Initiation day (mv/niv/hfnc)',
						1 as oxysupp_init label='Start of a new Initiation period (Y/N) (ie, no NIV/HFNC or MV, in previous calendar day)'
				from Resp_mv_nivhfnc2_init  ;
				quit;

				/**Take min(oxysupp_day) for each encounter... this indicates  start of Init Period (ie. no NIV/HFNC or MV, in previous calendar day;
				** WILL INCORPORATE THIS DATASET IN A LATER STEP @line 1186  *****/

/*(3) Calculate number of consecutive days for each encounter (there may be >1 episode in ea encounter) */

		/**  BASED ON SAS Macro to Count Consecutive Days within group/id
			 REF:  https://support.sas.com/resources/papers/proceedings/proceedings/sugi29/069-29.pdf    **/


	/***(3a) sorting data by subject and date *****/
		proc sort data=Resp_mv_nivhfnc2 nodupkeys;
		by adm_id oxysupp_date;
		run;

			/*****flagging the same number when date is consecutive to the previous date *****/
			data resp_consec1;
			set Resp_mv_nivhfnc2;
			by adm_id oxysupp_date;
			tempdate=lag(oxysupp_date);
			if first.adm_id then tempdate=.;
			retain cflag;
			if first.adm_id then cflag=1;
			if oxysupp_date ne tempdate+1 then cflag=cflag+1;
			format tempdate mmddyy10.;
			run;

	/**(3b) counting the number of same flags *****/
		data resp_consec2(keep= adm_id cflag consecutive);
		set resp_consec1;
		by adm_id cflag;
		retain consecutive;
		if first.cflag then consecutive=0;
		consecutive=consecutive+1;
		if last.cflag and consecutive>=2;
		run;

	/***(3c) merging two counts with one (original) *****/
		data resp_consec3;
		merge resp_consec1 resp_consec2(in=a);
		by adm_id cflag;
		if a;
		run;

	/***(3d) getting one observation per subject when it has at least required consecutive day ***/
		proc sort data=resp_consec3;
		by adm_id cflag oxysupp_date;
		run;

			data resp_consec4;
			set resp_consec3;
			by adm_id cflag oxysupp_date;
			retain firstdate;
			if first.cflag then firstdate=oxysupp_date;
			lastdate=oxysupp_date;
			format lastdate firstdate mmddyy10.;
			if last.cflag;
			run;

					proc sort data=resp_consec4(drop=cflag oxysupp_date tempdate) out=mv_nivhfnc_consec;
					by adm_id firstdate;
					run;


/*(4) Create abbrev version of CONSEC DAYS */
			proc sql;
			create table mv_nivhfnc_consec2 as
			select adm_id,
					patientID,
					admission_date,
					discharge_date,
					niv_hfnc,  /* indicates nippv OR hfnc */
					mechvent,			
					consecutive as n_consecdays,
					firstdate format mmddyy10.,
					lastdate format mmddyy10.

			from mv_nivhfnc_consec;
			quit;


/*(5) Merge with infection dataset (want to keep records where firstdate falls within infection window)  */
		/*(Merge INFECTION with MV_NIVHFNC_CONSEC3 dataset:  
	 	  Limit to records where first consecutive date (FIRSTDATE) falls within Infection Window (infxn_ONSET_DT +/- 1 days)***/

			 proc sql;
			 create table mv_nivhfnc_consec3 as
			 select b.*, 
					a.infxn_onsetDT, 
					a.infxn_onset_day
			 from infection as a INNER JOIN mv_nivhfnc_consec2 as b
			 on a.adm_id=b.adm_id 
			 where (b.firstdate - a.infxn_onsetDT) in (-1, 0, 1) ;
			 quit;



/*(6) Create MASTER mv_nivhfnc dataset ==>  Join list of CONSEC days with OXYSUPP day as oxysuppnew_day;
			 *where firstdate (from CONSECDAYS) = oxysupp_date (initation date of "new" oxysupp); **/

	proc sql;
	create table main_niv  as
	select a.*, 
				b.oxysupp_day as oxysuppnew_day,
				b.oxysupp_init_day,
				b.oxysupp_date as oxysupp_init_date format mmddyy10.
	from mv_nivhfnc_consec3 as a INNER JOIN Resp_mv_nivhfnc2_init2   as b
	on a.adm_id=b.adm_id and (a.firstdate= b.oxysupp_date);
	quit;


/*(7) MERGE MAIN_NIV dataset back to RESP_MV_NIVHFNC3  dataset (get daily-level records);
	/** This is a daily-level list of all OXYSUPP (mv/niv/hfnc) records
			-associated with infection_anchor_day - need to limit
			-oxysuppnew (to indicate initiation of new oxysupp)
			-nconsec days  ****/

	proc sql;
	create table main_niv2 as
	select	a.*,
			b.n_consecdays,
			b.oxysupp_init_date, 
			b.oxysupp_init_day 

	from Resp_mv_nivhfnc3  as a LEFT JOIN main_niv as b
	on a.adm_id=b.adm_id and a.infxn_onsetDT=b.infxn_onsetDT;
	quit;	

		/*Limit to relevant records with valid measures for consec days and oxysuppnew_day (initiation);
		** ie, remove records with missing values for n_consecdays and oxysupp_init_day;
	    ** REMEMBER, this section ONLY focuses on HFNC/NIV for consec days... **/

		data main_niv3 ;
		set main_niv2;
		where n_consecdays ne . and oxysupp_init_day   ne .;
		run;

/*(8) Limit to records where  oxysupp_day  occurs within +/- 1 day of infxn_onset_day and (oxysupp_day ge oxysupp_init_day [from INIT dataset]) **/
		data main_niv4;
		set main_niv3 ;
		where (infxn_onset_day-1 le oxysupp_day le infxn_onset_day+1) and (oxysupp_day ge  oxysupp_init_day ); 
		run;
  

/*(9) Create infID to demarcate separate infection periods **/
	data main_niv5 ;
	set main_niv4  ;
	format infID $11.;
	infID=compress(adm_id||"_"||infxn_onset_day);
	label infID="Infection period: adm_id + infxn_onset_day";
	run;

		proc sql;
		create table  main_niv6  as
		select distinct infID, *
		from  main_niv5  ;
		quit;


/*(10) Identify NIV_HFNC cases that start out with NIV/HFNC on day 1 and escalate to Mech Vent on day 2  (these are allowed in NIV_HFNC OD) */

	/*(10a) Sort data by adm_id, infxn_onset_day and oxysupp_day */
	proc sort data= main_niv6;
	by  infID oxysupp_day;
	run;

	/*(10b) ID min oxysupp_day */
		proc sql;
		create table main_niv7  as
		select *, 
		min(oxysupp_day) as oxysupp_day_first
		from main_niv6 
		group by infID
		order by infID;
		quit;


	/*(10c) ID consec days of oxysupp that start out on MechVent --> we don't want these... will delete these encounters;
		      *Use to ID de-escalating respiratory OD, where MV de-escalates to NIV/HFNC on next day.  Want to Exclude these; */
		data main_niv8 ;
		set main_niv7 ;
		if oxysupp_day=oxysupp_day_first and mechvent=1 then flag_mv_first=1; else flag_mv_first=0;
		run;

	/*(10d) To further define de-escalating OXYSUPP, do not count NIV/ HFNC if there was MechVent the prior day. ***/
			/*** ==>  WILL ID BY MERGING BACK TO RESP_MECHVENT_FNL **/

			* create summary-level vbl for inf_id;
			proc sql;
			create table main_niv9 as
			select *,  max(flag_mv_first) as flag_mvfirst_infpd
			from main_niv8 
			group by infID
			order by infID;
			quit;

				*Delete all consec_day series that start with mechvent (RECALL: MV organ dysfunction is addressed separately);
				data main_niv10;
				set main_niv9 ;
				if flag_mvfirst_infpd=1 then delete;
				drop flag_mv_first flag_mvfirst_infpd;
				run;

					*Rearrange vbls;
					proc sql;
					create table main_niv11 as
					select distinct adm_id, patientID, infID,
						infxn_onset_day,
						oxysupp_init_day,
						oxysupp_day,
						niv_hfnc,
						mechvent
					from main_niv10 ;
					quit;


	/**(10e) PARE DOWN DATASET  **/
				*Limit to records that fall within +/- 2 day of infxn_onset_day;
				**NOTE:  Even though infxn window is +/- 1 day, use a wider window to assess consec days that are initiated on tail end (-1) of first consec day);
				data main_niv12 ;
				set main_niv11 ;
				where -2 le (oxysupp_day-infxn_onset_day) le 2;
				run;


		*Collapse/create 1 row for every infection achor day (infID);
		proc sql;
		create table main_niv13_infid as
		select distinct adm_id, patientID, infID, infxn_onset_day, 
						oxysupp_init_day as od_nivhfnc_firstday, 
						max(niv_hfnc) as od_nivhfnc label='initiation of NIV HFNC for 2+ consec days'
		from main_niv12
		group by infID
		order by infID;
		quit;
								


/*(11) merge HFNC/NIV back to MECHVENT_INIT to see if any consec days BEGIN with a MECH VENT then consider this de-escalation and delete   *******/

*Create INF_PD variable in mechvent dataset;
data resp_mechvent_fnl2;
set resp_mechvent_fnl;
	format infID $11.;
	infID=compress(adm_id||"_"||infxn_onset_day);
	label infID="Infection period: adm_id + infxn_onset_day";
run;

	*Create INF_PD variable in INFECTION  dataset (replacing basic_bc);
	proc sql;
	create table infection2 as
	select distinct adm_id, patientID, admission_date, discharge_date, infxn_onset_day, infxn_onsetDT
	from infection;
	quit;

		data infection3;
		set infection2;
			format infID $11.;
			infID=compress(adm_id||"_"||infxn_onset_day);
			label infID="Infection period: adm_id + infxn_onset_day";
		run;


	*Merge MECH VENT to INFECTION3;
	proc sql;
	create table resp_mechvent_fnl3 as
	select a.infID, a.*, b.*
	from infection3 as a LEFT JOIN resp_mechvent_fnl2 as b
	on a.infID=b.infID;
	quit;



	*MERGE IN NIV/HFNC DATASET;
	proc sql;
	create table od_resp  as
	select a.*, b.*
	from resp_mechvent_fnl3 as a LEFT JOIN main_niv13_infid  as b
	on a.infID=b.infID;
	quit;

		*Create FLAG to ID cases with de-escalating Resp OD;
		/*NOTE: de-escalation flag is only valid if diff= -1.  
		  If diff > 1 day, then its not consecutive (eg,  Vent on day 1/ BIPAP on day 3 ****/
		data  od_resp2 ;
		set  od_resp;
		diff=(mechvent_min_day- od_nivhfnc_firstday);
		if diff=-1 then flag_remove_de_esc=1;   
		run;


	*keep records with BOTH HFNC & MECHVENT INIT (will delete these, as they are de-escalation);  
	data od_resp3;
	set od_resp2;
	if flag_remove_de_esc=1 then delete;
	drop flag_remove_de_esc;
	rename od_nivhfnc=niv_hfnc od_nivhfnc_firstday=nivhfnc_minday;
	run;

		*Keep only relevant records;
		data od_resp4_penult;
		set od_resp3;
		where (mechvent=1  or  niv_hfnc=1) ;
		drop oxysupp_day_first oxysuppnew_day od_day diff;
		run;

			proc sql;
			create table od_resp5 as
			select distinct infID, 
							adm_id, 
							patientID, admission_date, discharge_date,
							infxn_onset_day, 
							mechvent,
							mechvent_min_day,
							niv_hfnc  as od_nivhfnc label='Resp OD: Initiation of NIV/HFNC for 2+ consec days' , 
							nivhfnc_minday
			from od_resp4_penult;
			quit;


/* (12) Final Datasets **/

	/*Final nivhfnc subset */
	data resp_nivhfnc_fnl;
	set od_resp5;
	where od_nivhfnc=1;

	drop infID mechvent mechvent_min_day;
	run;

	/*Final mechvent subset */
	data resp_mechvent_fnlfnl;
	set od_resp5;
	where mechvent=1;

	drop infID od_nivhfnc niv_hfnc_minday;
	run;


	/*Create FINAL OD_RESP datataset that combines NIV & Vent into a single respiratory OD */
	data od_resp6;
	set od_resp5;
	if mechvent=. then mechvent=0;
	if od_nivhfnc=. then od_nivhfnc=0;
	od_resp=max(mechvent, od_nivhfnc);
	label od_resp='Any respiratory OD (mechvent or niv_hfnc)';

	od_resp_minday=min(mechvent_min_day, nivhfnc_minday);
	label od_resp_minday='min(mechvent_min_day, nivhfnc_minday)';
	run;

		/** Save as tmp dataset for future reference (contains daily-level oxysupp records,  
			data already limited to records that fall within Infx window (ifnx_onset day +/- 1 day), 
			consecutive days identified, and start of consec days falls on initiation of new oxysupp */
				data tmp.od_resp_mvnivhfnc_penult;
				set od_resp6;
				run;


/**(13)  Create final NIV_HFNC dataset **/

			   data od_resp_fnl;
			   set od_resp6;
			   drop infID;
			   run;
								

/********************  END RESPIRATORY OD *******************************/




/*** BEGIN  LABS OD  *******************************************/
/*** BEGIN  LABS OD  *******************************************/



/* Limit clinical data to records from admisssion_day-1 (hosp day 0) through discharge **/

data laboratory;
set raw.&laboratory ;
rename lab_day=Day;
where lab_day ge 0;
run;
			

/******************************************************************************/
/* LABS: Serum Lactate 						                                      */
/******************************************************************************/
	/********************************************************************************************************/
	/* Serum lactate must be >2.0 mmol/L																	*/
	/*            -AND- and increasing from the worst value on the prior calendar day.            			*/
	/********************************************************************************************************/

	/**(1) MERGE LACTATE TO BASIC*/
		proc sql;
		    create table serum_lactate as
		        select distinct a.adm_id,
								b.admission_date, b.discharge_date,
		                        a.patientID,
								a.Day,
								a.date,
								a.maxLAC 
		        from laboratory a,
		             basic_fnl b
		        where a.adm_id = b.adm_id and a.patientID = b.patientID 
		               and a.Day  <= b.Discharge_day ;
		quit;

	/*(2) Create flag to ID records where LAC >2.0*/
				data serum_lactate2;
				set serum_lactate;
				if maxLAC >2 then flag=1;
				run;


	/*(3) Create lag variable to identify cases with de-escalating Lactate (ie, with lower value than prior calendar day)*/
					proc sort data=serum_lactate2;
					by adm_id day;
					quit;


					data serum_lactate3;
					    set serum_lactate2;
					    by adm_id day;

					    /* Create a lagged variable for the lab value  */
					    Lagged_lactate = lag(maxLAC);

					    /* For the first observation of each patient, the lagged value should be missing */
					    if first.adm_id then Lagged_lactate = .;

					    /* Calculate the difference between the current and lagged values */
					    Difference = maxLAC-Lagged_lactate ;
					run;


	/*(4) Keep records where maxLAC >2;*/
				data serum_lactate4;
				set serum_lactate3;
				where flag=1;
				run;

	/*(5) Exclude Lactate values that de-escalated from previous day;*/
				/***  NOTE: Be sure to exclude lactate values that remain the same from previous day (where diff=0)*/
				data serum_lactate5;
				set serum_lactate4;
				if difference ne . and difference le 0 then delete;
				run;



	/*(6) Select cases with lactate >= 2 in +/- 1 days of Infection_onset_day*/
				proc sql;
				    create table serum_lactate6 as
				        select a.*,
				               b.infxn_onset_day
				        from serum_lactate5   	  a,
				             infection         b
				        where a.adm_id = b.adm_id and a.patientID = b.patientID and
				              -1 <= (a.Day - b.infxn_onset_day) <= 1;
				quit;

						proc sql;
						    create table lactate2_fnl as
						        select distinct adm_id,
						                        patientID,
						                        infxn_onset_day,
						                        min(Day) as lactate2_min_day,
						                        1 as lactate2 label='Lactate > 2.0'
						        from serum_lactate6
						        group by adm_id, patientID, infxn_onset_day;
						quit;


*** END LACTATE *************************************************/


****************************************************************************************************************************************
* LABS: Calculate BASELINE values for Creatinine, eGFR, Total Bilirubin, and Platelets   *
* --Limit to best values DURING hospitalization only (admit-1) and (discharge)--
****************************************************************************************************************************************;

/***************************************************************************************************************
						**  UPDATES TO BASELINE VALUES FOR ASE 2.0:

							RENAL (Creatinine):
							Require minimum creatinine threshold for AKI criteria based on gender:  1.18 for males, 1.02 for females
							-->> (i.e,, still requires a doubling in creatinine, but to the above minimum threshold – so going from creatinine of 0.3 to 0.7 would not count)

							For patients who die or are discharged to hospice, assume normal baseline creatinine value 
							UNLESS patients has discharge diagnosis codes for Elixhauser moderate-severe renal failure (POA only - see appendix)
							-->> i.e., if dx_elix_renal=0 and dc to hospice/death then assume normal BL creat values;  else if dx_renal=1, then use face value of actual creat lab values [NEW 7/1/25]

							LIVER (Bilirubin) [Def 3 is new 9/28/24]
							-Def 2: For patients who die or are discharged to hospice, assume normal baseline bilirubin value (0.5) unless discharge diagnosis codes 
							for Elixhauser Moderate-Severe Liver Disease are present (POA only - see appendix)

							-Def 3: Exclude all patients from meeting  bilirubin criteria if they have discharge dx icd10 codes for Elix Mod-Severe Liver disease codes (POA only), 
							  OR POA hemolytic anemia (D55x, D56x, D57x, D58x, and D59x).  
							 If they do not meet this exclusion criteria – for patients who die or are discharged to hospice, assume normal baseline bilirubin value (0.5).

							COAGULATION (Platelets):
							For patients who die or are discharged to hospice, assume normal baseline platelet value (200).  
							Also exclude all patients from meeting platelet criterion (regardless of their hospitalization outcome) 
							if they have any Elixhauser diagnoses for cancer (Leukemia, Lymphoma, Solid Tumor without mets, solid tumor with mets) (POA or not POA - see appendix)


						***ADDITIONAL CLARIFICATION 7/30/25:

										For Renal, Hepatic and Coagulation OD (both CO and HO-ASE)
										• If a patient has icd10 codes for end stage kidney disease, they are excluded from Renal OD
										• If a patient has icd10 codes for Elix Liver disease or hemolytic anemia, they are excluded from Hepatic OD
										• If a patient has icd10 codes for Elix cancer, they are excluded from Coagulation OD
										 

										When determining baseline labs for CO-ASE only,
										• Assume normal baseline values for bilirubin and platelets if a patient dies or discharged to hospice
										• Assume normal baseline values for creatinine if a patient dies or discharged to hospice, unless they have icd10 codes for chronic renal failure 

***********************************************************************************************************************************************************/


/*(1) Rename variables from raw labs data [RECALL: labs are from hospday 0 through discharge] **/

data laboratory2;
set laboratory ;
rename  minCreat = Cr_min
        maxCREAT = Cr_max
        minEGFR  = Egfr_min
        maxEGFR  = Egfr_max
        minTBILI = Tbili_min
        maxTBILI = Tbili_max
        minPLT   = Plt_min
        maxPLT   = Plt_max
        minLAC   = lactate_min
        maxLAC   = lactate_max  
		lab_day  = Day;
run;



/*** COMMUNITY BASELINE LEVELS ******************/

	/*(1) MERGE LABS WITH BLOOD CULTURE DATA (use INFECTION dataset) **/

	proc sql;
	    create table baseline_comm_lab1 as
	        select a.adm_id,
	               a.patientID,
	               a.infxn_onset_day,
	               a.admission_date,
	               b.Discharge_date, 
	               b.discharge_date-b.admission_date+1 as discharge_day,
	               b.Day,
	               b.Cr_min,
	               b.Tbili_min,
	               CASE WHEN b.Egfr_max > 60 THEN 60
	                    ELSE b.Egfr_max
	               END as Egfr_max,
	               b.Plt_max
	        from infection   a,
	             laboratory2 b
	        where a.adm_id = b.adm_id and a.patientID = b.patientID and
			   0 <= b.Day <= calculated Discharge_Day;     
	quit;


		/* Add data from BASIC dataset (need gender, dc_disposition, and diagnosis_flag data)*/
		proc sql;
		create table baseline_comm_lab_1a as
		select a.*,
				b.gender,
				b.gender_txt,
				b.discharge_dispo,
				b.dd_group
		from baseline_comm_lab1 as a LEFT JOIN basic_fnl as b
		on a.adm_id=b.adm_id;
		quit;

		*Add diagnosis_flag data (DIAGNOSIS_FLAG dataset);
			proc sql;
			create table baseline_comm_lab_1b as
			select a.*,
				   b.*
			from baseline_comm_lab_1a as a LEFT JOIN raw.diagnosis_flag as b
			on a.adm_id=b.adm_id;
			quit;



	/* (2) COMMUNITY BASELINE LEVELS:  Establish baseline value (take min/max) */
			proc sql;
			    create table baseline_comm_lab2_new as
			        select adm_id,
			               patientID,
			               infxn_onset_day,
						   *,
						   min(Cr_min) as Cr_baseline,
			               min(Tbili_min) as Tbili_baseline,
			               max(Egfr_max) as Egfr_baseline,
			               max(Plt_max) as Plt_baseline
			        from baseline_comm_lab_1b  
			        group by adm_id, patientID, infxn_onset_day;
			quit;



	/* (3) COMMUNITY BASELINE LEVELS:  Tweak baseline values, based on icd10 codes */

			data baseline_comm_lab3_new;
			set baseline_comm_lab2_new;

				/***RENAL - Creatinine:  
					-Assume normal baseline values for creatinine OR THE LOWEST DURING HOSPITALIZATION- whichever is lower [Normal Baseline values are 1.18 mg/dL for males, 1.02 mg/dL for females] 
			      	 if a patient dies or discharged to hospice  
					 UNLESS they have ICD10 codes for Elix mod-severe renal failure (dx_elix_renal=1), in which case baseline values are based on actual lab values  
					-If a patient has icd10 codes for end stage kidney disease, they are excluded from Renal(CREAT) OD (CO- and HO-ASE)  **/
					

				*(a) Assume normal baseline values  if a patient dies / discharged to hospice  -OR- lowest values during hospiitalization(whichever is lower) - 
					 (unless ic10 codes for Elix Liver disease);
				 	if dx_elix_renal ne 1 and discharge_dispo in (4,5) then do;
						if gender in (.,1) then cr_baseline_new= min(1.18, cr_baseline);   /** Use whichever is lower:   baseline Creat or Normal Baseline values for males, as defined above **/ 
						if gender=2 then cr_baseline_new=min(1.02, cr_baseline);           /** Use whichever is lower:   baseline Creat or Normal Baseline values for females, as defined above **/ 
					end;
					else  cr_baseline_new = cr_baseline;

				*(b)If a patient has icd10 codes for end stage kidney disease only (NOT dx_elix_renal), they are excluded from Renal(CREAT) OD (CO- and HO-ASE);
					**==> [NOTE:  This is addressed at a later step in mk_creat_new macro (line 2003)];


				/**LIVER3_NEW [7/30/25] :  
				 	-Assume normal baseline values for bilirubin and platelets if a patient dies or discharged to hospice
					-If a patient has icd10 codes for Elix Liver disease or hemolytic anemia, they are excluded from Hepatic(BILI) OD (CO- and HO-ASE);    ****/

				*(a) Assume normal baseline values f if a patient dies / discharged to hospice;
					if discharge_dispo in (4,5) then tbili_baseline_new3 = 0.5;
						else  tbili_baseline_new3 = tbili_baseline;
			
				*(b) If a patient has icd10 codes for Elix Liver disease or hemolytic anemia, they are excluded from Hepatic(BILI) OD (CO- and HO-ASE);
					if dx_elix_liver=1 or dx_anemia_poa=1 		then tbili_baseline_new3 = . ;


				/*PLATELETS_NEW [7/30/25]:  Plt_max
				 	-Assume normal baseline values for bilirubin and platelets if a patient dies or discharged to hospice
					-If a patient has icd10 codes for Elix cancer, they are excluded from Coagulation (PLT) OD (CO- and HO-ASE)    *****/

				*(a) Assume normal baseline values if a patient dies / discharged to hospice;
					if discharge_dispo in (4,5) then plt_baseline_new=200;
							else plt_baseline_new = plt_baseline;

				*(b)  If a patient has icd10 codes for Elix cancer, they are excluded from Coagulation (PLT) OD (CO- and HO-ASE);
					if dx_elix_cancer=1 	then plt_baseline_new = . ;




			run;


	/* (4) CREATE Final dset for Baseline_labs_comm */
			proc sql;
			create table baseline_comm_final as
			select distinct adm_id,
					patientID,
					infxn_onset_day,
					gender_txt,
					dd_group, 
					dx_elix_liver,
					dx_anemia_poa,
					dx_elix_renal,
					dx_elix_cancer,
					cr_baseline,
					tbili_baseline,
					egfr_baseline,
					plt_baseline, 
					cr_baseline_new,							  
					tbili_baseline_new3 as tbili_baseline_new,   
					plt_baseline_new							 


			from baseline_comm_lab3_new
			group by adm_id, patientID, infxn_onset_day
			order by adm_id, patientID, infxn_onset_day;
			quit;


/** END COMM BASELINE LEVELS (LABS) ******************/

/** HOSPITAL BASELINE LEVELS (LABS) */
		
	**(1a)  Merge BASIC data with INFECTION dataset;
		proc sql;
		    create table basic_inf as
		       select distinct a.adm_id,
		                       a.patientID,
							   a.admitSource,
				               a.Discharge_date, 
				               a.discharge_date-a.admission_date+1 as discharge_day,
		                       b.infxn_onset_day,
							   a.gender,
							   a.gender_txt,
							   a.discharge_dispo,
							   a.dd_group

		       from basic_fnl a,
		            infection b
		       where a.adm_id = b.adm_id and a.patientID = b.patientID;
		quit;
									

			/*(1b) Merge in Lab dataset;
				** Update for ASE 2.0, where hosp-baseline levels are based on (infection_onset_date-2) -- only looking backwards.
					(want best values in the 2 days prior to infection_onset_date) */

				proc sql;
				    create table baseline_hosp_lab1 as
				        select a.adm_id,
				               a.patientID,
				               a.infxn_onset_day,
							   a.discharge_day,
							   a.gender,
							   a.gender_txt,
							   a.discharge_dispo,
							   a.dd_group,
				               b.Day,
				               b.Cr_min,
				               b.Tbili_min,
				               CASE WHEN b.Egfr_max > 60 THEN 60
				                    ELSE b.Egfr_max
				               END as Egfr_max,
				               b.Plt_max
				        from basic_inf  	  a,
				             laboratory2	  b
				        where a.adm_id = b.adm_id and a.patientID = b.patientID and
				              -2 <= (b.Day - a.infxn_onset_day) <=0;
				quit;



	/*(2) HOSPITAL BASELINE LEVELS:  Establish baseline value (take min/max) */

	proc sql;
	    create table baseline_hosp_lab2 as
	        select adm_id,
	               patientID,
	               infxn_onset_day,
				   *, 
	               min(Cr_min) as Cr_baseline,
	               min(Tbili_min) as Tbili_baseline,
	               max(Egfr_max) as Egfr_baseline,
	               max(Plt_max) as Plt_baseline
	        from baseline_hosp_lab1
	        group by adm_id, patientID, infxn_onset_day;
	quit;


	/*(3)  HOSP BASELINE LEVELS: Add Diagnosis Flag data */
				proc sql;
				create table baseline_hosp_lab2a as
				select  a.*,
						b.*

				from baseline_hosp_lab2 as a LEFT JOIN raw.diagnosis_flag as b
				on a.adm_id=b.adm_id;
				quit;

	/* (4) HOSP BASELINE LEVELS:  Tweak baseline values, based on icd10 codes */

	       /****************************************************************************
			ASE 2.2 Tweak to baseline labs for HO-ASE: 
		
			CHANGES for ASE 2.2:
			==> (1) The rule for assuming normal baseline values ONLY applies to baseline labs for CO-ASE;
			==> (2) The rule for excluding OD for creatinine, bilirubin and/or platelets based on the presence of specific ICD-10 codes applies to CO-ASE and HO-ASE.

			So...
			if dx_elix_renal=1 or endstage renal disease 	then exclude od_creatinine (reset baseline value to missing)
			if dx_elix_liver=1 or dx_anemia_poa=1 			then exclude od_bilirubin (reset baseline value to missing)
			if dx_elix_cancer=1 							then exclude od_platelet (reset baseline value to missing)

			*****************************************************************************************/
			
			data baseline_hosp_lab3;
			set baseline_hosp_lab2a;

				/*RENAL: If patient has discharge dx codes for end-stage renal disease, then exclude from Renal OD (CO- and HO-ASE) -- addressed in a later step **/
				 /*	if dx_elix_renal=1 then cr_baseline_new = .;
					else  cr_baseline_new = cr_baseline;   */

					cr_baseline_new = cr_baseline;

				/**LIVER3: HO-ASE only: Exclude all patients from meeting  tbili criteria if they have discharge dx icd10 codes for:
					  Elix Mod-Severe Liver disease codes (POA only)  -OR- POA hemolytic anemia (D55x, D56x, D57x, D58x, and D59x)  
					  -->> [ie:  exclude if (dx_elix_liver=1 or  dx_anemia_poa=1)
					             include if (dx_elix_liver=0 and dx_anemia_poa=0)  */
					
					*Exclusion of patients meeting Dx code exclusion criteria;
					if (dx_elix_liver=1 or dx_anemia_poa=1) then tbili_baseline_new3=.;
					else  tbili_baseline_new3 = tbili_baseline;

				/*PLATELETS:  HO-ASE only:  Plt_max
					EXCLUDE ALL patients from meeting platelet criterion (regardless of their hospitalization outcome) 
					if they have any Elixhauser diagnoses for cancer (Leukemia, Lymphoma, Solid Tumor without mets, solid tumor with mets) (POA or not POA ) */
				 	if dx_elix_cancer=1 then plt_baseline_new=.;
					else plt_baseline_new = plt_baseline;
			run;


	/* (5) CREATE Final dset for Baseline_labs_hosp */

			proc sql;
			create table baseline_hosp_final as
			select distinct adm_id,
					patientID,
					infxn_onset_day,
					gender_txt,
					dd_group, 
					dx_elix_liver,
					dx_anemia_poa,
					dx_elix_renal,
					dx_elix_cancer,
					cr_baseline,
					tbili_baseline,
					egfr_baseline,
					plt_baseline, 
					cr_baseline_new,
					tbili_baseline_new3 as tbili_baseline_new, 
					plt_baseline_new


			from Baseline_hosp_lab3
			group by adm_id, patientID, infxn_onset_day
			order by adm_id, patientID, infxn_onset_day;
			quit;

/** END HOSPITAL BASELINE LEVELS (LABS) */


/**************************************************/
/**FINAL LABS OD (combine with baseline-levels)  **/
/**FINAL LABS OD (combine with baseline-levels)  **/
/**************************************************/

***********************************************************************************
* Retrieve lab data within +/- 1 days of infxn_onset_day                           *
***********************************************************************************;

/****** this DATA ALREADY PULLED IN FOR BASELINE VALUES ***


				*(1) PULL IN LAB dataset & rename vbls;
				data laboratory2;
				set laboratory ;
				rename  minCreat = Cr_min
				        maxCREAT = Cr_max
				        minEGFR  = Egfr_min
				        maxEGFR  = Egfr_max
				        minTBILI = Tbili_min
				        maxTBILI = Tbili_max
				        minPLT   = Plt_min
				        maxPLT   = Plt_max
				        minLAC   = lactate_min
				        maxLAC   = lactate_max  
						lab_day  = Day;
				run;

*******/

proc sql;
    create table inf_lab1 as
        select distinct a.adm_id,
                        a.patientID,
                        a.infxn_onset_day,
                        b.Day,
                        b.Cr_max,
                        b.Tbili_max,
                        b.egfr_min,
                        b.Plt_min
        from infection a,
             laboratory2  b
        where a.adm_id = b.adm_id and a.patientID = b.patientID and
              -1 <= b.Day - a.infxn_onset_day <= 1;
quit;


**********************************************************************************
* Select cases with doubling of creatinine relative to baseline(community)       *
***********************************************************************************;


/** Renal disease cases (for Bilirubin OD):
    Exclude cases with end-stage renal disease (ESRD) icd10 N186*/

data renal_disease_;
set raw.diagnosis;
    if (index(upcase(diagnosiscode),'N186') > 0) or (index(upcase(diagnosiscode),'N186') > 0) 
    then es_renal_dis=1; else es_renal_dis=0; 
run;

    data renal_disease;
    set renal_disease_;
    where es_renal_dis=1;
    run;



/**********************************************************************************************************************
 *[9/24/24]Create new RENAL Organ Dysfunction for ASE 2.1: 
	*Remove eGFR criteria from renal dysfunction;
	*Require a doubling in serum creatinine to > 1.18 for males/ >1.02  for females)… 
	*If discharge disposition is death or hospice asume normal baseline creatinine (1.18 for males; 1.02 for females)
	 unless Elix codes for mod_severe renal disease  
***********************************************************************************************************************/

*[9/24/24]: UPDATED MACRO FOR RENAL ORGAN DYSFUNCTION [mk_cregfr_new Macro] - Creatinine only/ no eGFR  ;
*[8/13/24]: UPDATED with infxn_onset_day;

%macro mk_creat_new(type);

	*[9/24/24]: Limit to records where Creat-levels doubled from baseline. Add gender & use cr_baseline_new*;
    proc sql;
        create table &type._cr1a_new as
            select a.adm_id,
                   a.patientID,
                   a.infxn_onset_day,
                   a.Day,
				   b.gender_txt,
                   a.Cr_max,
                   b.Cr_baseline_new    
            from inf_lab1 a,
                 baseline_&type._final  b
            where a.adm_id = b.adm_id and a.patientID = b.patientID and
                  a.infxn_onset_day = b.infxn_onset_day;

			quit;

	*[7/18/25] Add extra data step that EXCLUDES baseline measures that are missing (these are labs that meet criteria for exclusion)*;
	data &type._cr1b_new;
	set  &type._cr1a_new;
	where not missing(Cr_max) and not missing(Cr_baseline_new)
                  and
               Cr_max >= 2 * Cr_baseline_new and 
			   Cr_max > 0 ;
    run;

	*LIMIT to minimum creatinine threshold (> 1.18 for males/ >1.02  for females);
	data &type._cr1c_new;
	set  &type._cr1b_new;
	where (gender_txt in ('Male', 'Unknown') and Cr_max > 1.18) or (gender_txt='Female' and Cr_max > 1.02);
	run;


	*Limit to vbls of interest;
    proc sql;
        create table &type._cr2_new as
            select adm_id,
                   patientID,
                   infxn_onset_day,
                   min(Day) as Cr_new_&type._min_day,
				    min(Day) as Cr_new_&type._max_day,
                   1 as Cr_new_&type.
            from &type._cr1c_new
            group by adm_id, infxn_onset_day
			order by adm_id, infxn_onset_day;  
    quit;

    ** EXCLUDE CASES WITH RENAL_DISEASE;
    proc sql;
        create table cr_new_&type._keep as
            select adm_id, patientID 
		from &type._cr2_new 
                EXCEPT CORR
            select adm_id, patientID from renal_disease;
    quit;

    proc sql;
        create table &type._cr_new_fnl as
            select distinct a.*
            from &type._cr2_new  	 a,
                 cr_new_&type._keep  b
            where a.adm_id = b.adm_id and a.patientID = b.patientID;
    quit;



%mend mk_creat_new;

%mk_creat_new (type = COMM);
%mk_creat_new (type = HOSP);



***********************************************************************************
* Select cases with Total bilirubin >= 2.0 mg/dL and increase by 100% from        *
* baseline(community)                                                             *
* NOTE: Exclusion Criteria has been incorporated into BASELINE lab datasets 	  *
*        (where bili_baseline_new=.) 											  *
***********************************************************************************;

*[9/24/24]: updated macro for renal organ dysfunction [mk_tbili_new Macro]   ;
*[7/18/25] Add extra data step that EXCLUDES baseline measures that are missing (these are labs that meet criteria for exclusion)*;
*[8/13/24]: UPDATED with infxn_onset_day;

%macro mk_tbili_new3(type);

    * Cases with Total bilirum >= 2.0 and Total bilirum >= 2 * baseline value;

    proc sql;
        create table &type._tbili_new as
            select a.adm_id,
                   a.patientID,
                   a.infxn_onset_day,
                   a.Day,
                   a.Tbili_max,
                   b.tbili_baseline_new 
             from inf_lab1 a,
                  baseline_&type._final  b
             where a.adm_id = b.adm_id and 
				   a.patientID = b.patientID and
				   a.infxn_onset_day = b.infxn_onset_day;
			quit;

	data &type._tbili_new2;
	set  &type._tbili_new ;
	where  not missing(Tbili_max) and not missing(Tbili_baseline_new) and 
	     Tbili_max >= 2.0 and
	     (Tbili_max >= 2 * Tbili_baseline_new and Tbili_max > 0 and
                   Tbili_baseline_new > .);
	run;
   

    proc sql;
        create table &type._tbili_new_fnl as
            select distinct adm_id,
                            patientID,
                            infxn_onset_day,
                            min(Day) as tbili_new_&type._min_day,
                            1 as tbili_new_&type.
            from &type._tbili_new2
            group by adm_id, patientID, infxn_onset_day
			order by adm_id, patientID, infxn_onset_day;
    quit;

%mend mk_tbili_new3;

%mk_tbili_new3(type = COMM);
%mk_tbili_new3(type = HOSP);



***********************************************************************************
* Select cases with Platelet count < 100 cells/ul and decline by 50% from         *
* baseline(community)                                                             *
***********************************************************************************;


/**EXCLUDE WHERE plt_baseline_new=.  */
%macro mk_platelet_new(type);
    proc sql;
        create table &type._platelet1_new as
            select a.adm_id,
                   a.patientID,
                   a.infxn_onset_day,
                   a.Day,
				   b.dx_elix_cancer,
                   a.Plt_min,
                   b.Plt_baseline_new
             from inf_lab1 a,
                  baseline_&type._final   b
             where a.adm_id = b.adm_id and a.patientID = b.patientID and
                   a.infxn_onset_day = b.infxn_onset_day;
			quit;

	/** [7/18/25] Add extra data step that EXCLUDES baseline measures that are missing 
	   (these are labs that meet criteria for exclusion)*/
		data &type._platelet2_new;
		set &type._platelet1_new;
		where  not missing(plt_min) and not missing(plt_baseline_new) and 
		  		Plt_min < 100 
					and 
				Plt_baseline_new >= 100  
					and 	
                Plt_min <= 0.5 * Plt_baseline_new ;
		run;

    proc sql;
        create table &type._platelet_new_fnl as
            select distinct adm_id,
                   patientID,
                   infxn_onset_day,
                   min(Day) as Plt_new_&type._min_day,
                   1 as plt_new_&type.
            from &type._platelet2_new
            group by adm_id, patientID, infxn_onset_day
 			order by adm_id, patientID, infxn_onset_day;
    quit;

%mend mk_platelet_new;

%mk_platelet_new(type = COMM);
%mk_platelet_new(type = HOSP);


/*** END  LABS OD  *******************************************/
/*** END  LABS OD  *******************************************/



/************************************************************************************
* Combine organ dysfunction criteria with infection data                            *
/***********************************************************************************/



/**MACRO TO COMBINE INDIV OD datasets */

*Save individual dataset to FINAL library *;


	/*(1) Pull in Infection Subset **/
	data infection;
	set sepsis.Ehr_infection/* &infection  **/;
	infection=1;
	run;	
		proc sort data=infection;
		by adm_id patientID infxn_onset_day;
		run;
			

option spool;


*Macro to sort each dataset before merging;
%macro sort (dsname= );
		proc sort data=&dsname.;
		by adm_id patientID infxn_onset_day;
		run;
%mend sort;

*RUN SORT MACRO;
	%sort (dsname= vasopressor_fnl);
	%sort (dsname= hotn_fnl);

	%sort (dsname= od_resp_fnl );   /*Use OD_RESP_FNL dataset instead of individual dsets (resp_mechvent_fnlfnl & resp_nivhfnc_fnl) */
	
	%sort (dsname= lactate2_fnl );
	%sort (dsname= comm_cr_new_fnl);
	%sort (dsname= hosp_cr_new_fnl);
	%sort (dsname= comm_tbili_new_fnl);
	%sort (dsname= hosp_tbili_new_fnl);
	%sort (dsname= comm_platelet_new_fnl);
	%sort (dsname= hosp_platelet_new_fnl);
	%sort (dsname=infection );
/*******/

/*(2) COMBINE OD Subsets **/
	/**[8/13/25]: MAYBE USE THIS DATASET?: 9/3/25 - NO
			Hotn_pressor_esc_fnl dataset
			od_hotnprssr_esc  od_day_hotnprssr_esc
	***********************/
    data ehr_organ_dys  (drop = i);

            merge vasopressor_fnl 
            		hotn_fnl  
                  od_resp_fnl /*resp_mechvent_fnlfnl resp_nivhfnc_fnl */
                  lactate2_fnl 		
		comm_cr_new_fnl			hosp_cr_new_fnl 
		comm_tbili_new_fnl		hosp_tbili_new_fnl
		comm_platelet_new_fnl	hosp_platelet_new_fnl		
                  infection (keep = adm_id patientID  QAD_first infxn_anchor_day infxn_onset_day infection);
            by adm_id patientID infxn_onset_day;

            *ARRAY to reset missing values to zero;
            array orgvar vasopressor_new /*vaso_cons*/ hotn3
  			   mechvent  od_nivhfnc  od_resp
                       Cr_new_comm  Cr_new_hosp 
			 lactate2  
			 tbili_new_COMM  tbili_new_hosp  	
			 Plt_new_comm  Plt_new_hosp	;
            do over orgvar;
                if orgvar = . then orgvar = 0;
            end;

  /* INFXN_ONSET_DAY = min (infxn_anchor_day, QAD_first) **/
            /* -For Comm-onset Infection, infxn_onset_day should occur on hospital day 1,2,3     */
            /* -For hosp-onset infection, infxn_onset_day should occur on hospital days >= 4 */

            array mincomm [3]  cr_new_comm_min_day   Plt_new_comm_min_day  tbili_new_comm_min_day  ;
            array minhosp [3]  cr_new_hosp_min_day   Plt_new_hosp_min_day  tbili_new_hosp_min_day  ;
            array commvar [3]  cr_new_comm   		   plt_new_comm   		 tbili_new_comm ;
            array hospvar [3]  cr_new_hosp   		   plt_new_hosp    		 tbili_new_hosp ;

            do i = 1 to 3;
                if ~(. < infxn_onset_day < 4 ) then do;
                    commvar[i] = 0;
                    mincomm[i] = .;
                end;
            end;

            do i = 1 to 3;
                if ~(infxn_onset_day >= 4 ) then do;
                   hospvar[i] = 0;
                   minhosp[i] = .;
                end;
            end;
        run;


 *add admission_date to final dataset (using basic_final);
         proc sql;
         create table ehr_organ_dys2 as
         select  a.adm_id,
				 a.patientID,
                 a.admission_date,
                 a.admit_date_ed,
                 a.discharge_date,
				b.infection,
				b.QAD_first,
				b.*

         from basic_fnl  as a RIGHT JOIN ehr_organ_dys as b
         on a.adm_id=b.adm_id;
         quit;

*add recode for CVD organ dysfunction  ;
	data ehr_organ_dys3;
	set ehr_organ_dys2;
	od_cvd=max(vasopressor_new, hotn3);
	od_cvd_minday=min(vasopressor_min_day, hotn3_minday);
	label od_cvd='Cardiovascular OD (new vasopressor and/or new hypotension';

	*Reset missing values to zero;
    if infection=. then infection=0;
	run;

 *Select distinct;
         proc sql;
         create table ehr_organ_dys4 as 
         select distinct *
         from ehr_organ_dys3 ;
         quit;


/** Limit to vbls of interest***/

		proc sql;
		create table ehr_organ_dys4_abbrev as
		select distinct 	adm_id,
							patientID,
							admission_date,
							admit_date_ed,
							discharge_date,
							infection,
							QAD_first,
							infxn_anchor_day,
							infxn_onset_day,
							od_cvd, 
							od_cvd_minday as od_cvd_min_day,
							vasopressor_min_date,
							vasopressor_min_day,
							vasopressor_new,
							hotn3,
							hotn3_minday as hotn3_min_day,  
								
							od_resp_minday as od_resp_min_day,
							od_resp, 
							mechvent_min_day,
							mechvent,
							nivhfnc_minday as od_nivhfnc_min_day,
							od_nivhfnc,

							lactate2_min_day,
							lactate2,
							Cr_new_COMM_min_day,
							Cr_new_COMM,
							Cr_new_HOSP_min_day,
							Cr_new_HOSP,     

							tbili_new_COMM_min_day,
							tbili_new_COMM,
							tbili_new_HOSP_min_day,
							tbili_new_HOSP,

							Plt_new_COMM_min_day,
							plt_new_COMM,
							Plt_new_HOSP_min_day,
							plt_new_HOSP	
				from ehr_organ_dys4;
				quit;

		*Save to TMP library for future reference;	
		data tmp.ehr_organ_dys4_abbrev;
		set ehr_organ_dys4_abbrev;
		run; 

                            data ehr_organ_dys5;
                            set ehr_organ_dys4_abbrev;

							 *Update for ASE 2.1:  add recode for ANY_OD ;
	                                if (vasopressor_new=1 or hotn3=1 or
	                                    mechvent=1  or od_nivhfnc=1 or
	                                    lactate2=1 or 
	                                    max(cr_new_comm, cr_new_hosp)=1 or  
										max(tbili_new_comm, tbili_new_hosp)=1 or 
										max(plt_new_comm, plt_new_hosp)=1 )
	                                then od_any=1; else od_any=0;
	                                label od_any='Any ODs for ASE 2.2 (Pressor/hotn, MV/nivhfnc, Lac2, Cr_new, Bili_new, Plt_new)';

									n_od = sum( lactate2,  
												max(vasopressor_new, hotn3),
												max(mechvent,od_nivhfnc),
												max(cr_new_comm, cr_new_hosp),
												max(tbili_new_comm, tbili_new_hosp),
												max(plt_new_comm, plt_new_hosp));
	                                label n_od='N ODs for ASE 2.2 (Pressor/HOTN, MV/NIVHFNC, Lac2, Cr_new, Bili_new, Plt_new), max=6';

                            run;
		




/*********************************/
*Reorder vbls;
							proc sql;
							create table ehr_organ_dys6 as
							select  distinct   adm_id,
                                        patientID,
                                        admission_date,
                                        admit_date_ed,
                                        discharge_date, 
										infection,
										infxn_onset_day,
                                        infxn_anchor_day,
									  	QAD_first,
      									od_any,
										n_od, *
								from ehr_organ_dys5;
								quit;


                    /***************************************************************/
                    *SAVE TO PERM DATASET (all daily-rows with/out an OD);
					*There may be multiple rows per encounter   ;
                    /***************************************************************/

                            data sepsis.ehr_organ_dysfunction;
                            set ehr_organ_dys6;
                            run;


/********************************************************************************************************************/

/** FINAL QC ***/
/*Double check that n_id's matches total encounters in sepsis.ehr_organ_dysfunction dataset **/


proc contents varnum data=sepsis.ehr_organ_dysfunction;
run;


proc sql;
create table ckfinal as
select count(adm_id) as n_id, *
from ehr_organ_dys5
group by adm_id
order by adm_id;
quit;


title 'FINAL QC';
*Final QC;
proc freq data=ehr_organ_dys5;
tables od_any n_od
od_cvd
vasopressor_new
hotn3
od_resp
mechvent od_nivhfnc
lactate2
cr_new_comm cr_new_hosp  
tbili_new_comm tbili_new_hosp
plt_new_comm plt_new_hosp/missing;
run;


