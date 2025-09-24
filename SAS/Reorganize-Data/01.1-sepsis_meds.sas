
/***************************************************************************************
Program:	01.1-sepsis_meds

Created by:		Christina Chan

Date:	9/18/25

PURPOSE:  	Prepare MAPPED meds data into prelminary datasets for final Meds dataset
			Combine Encounters data with Mapped medications data (precursos to BASIC dataset)

NOTES:		- Vasopressor medication type includes IV norepinephrine, epinephrine, phenylephrine, dopamine, and vasopressin
			- Systemic antibiotics include antibacterials, antifungals, and antivirals.  

	Read in Primary EDW Encounters dataset
	 -Limit to encounters for which there is an antimicrobial prescribed  b/w admit and discharge_dates
	 -ID/remove repeat encounter rows (or with different discharge dates)

STEPS:
	(1) PULL IN MAPPED MEDS DATASET for antibiotics, antifungals/virals, pressors  (limit to meds admin b/w admission-2 and discharge); 
	(2) Create 1 set of MEDS data for ASE_2.0 - LIST OF DISTINCT MEDNAMES/ROUTES (for REFERENCE);

	(3) CREATE FINAL OUTPUT datasets for ANTIMICROBIAL (for ase_2.0) **/
			/*based on 4 categories:  PO_abx  PO_antifungal  IV_abx  IV_antifungal ***

	(4) Create final Vasopressor datasets [tmp.pressors & tmp.pressors_daily]


INPUT DATASETS:    derived.mapped_meds

OUTPUT DATASETS:

	Distinct list of mednames/routes (for REF):
	tmp.ase_2_0_medlist

	tmp.ase_2_0a
	tmp.antimicrobials_ase20
	tmp.iv_abx_exposed_days
	tmp.iv_antimicrobial_exp_days
	tmp.Po_abx_exposed_days
	tmp.po_antimicrobial_exp_days
	tmp.pressor
	tmp.pressor_daily;

			Note distinction b/w:
			pressor 
			o	ea row for ea unique medname & date
			o	there can be multiple rows per day;

			pressor_daily (daily-level)
			o	ea represents a single MRN/day, with multiple indicators for every pressor administred that day (so 1+ pressor can be indicated on a single day)
			o	lab values are presented as min/max values for each day

*************************************************************************************/

*v6.1 (EDW data refresh 2024);

*Filepaths to raw clinical data;
libname edw 'xxx';
libname derived 'yyy';


libname tmp 'zzz\Reorganize Data v6.3\Tmp';





/** (1) PULL IN MAPPED MEDS DATASET for antibiotics, antifungals/virals, pressors   *******/

	 data meds;
	 set derived.Mapped_meds_allmgb_2021_2023;
	 med_date=datepart(medicationTakenDTS);
	 format med_date YYMMDD10.;
	 run;

	*Limit to all med administration with in admission-1 and discharge;
		data meds2;
		set meds;
		med_day=(med_date-admission_date)+1; 
		where admission_date-1 le med_date le discharge_date; 
		drop  route_abx_new  route_new;
		
		run;

	 /** Re-arrange variables  **/

			proc sql;
			create table meds3 as 
			select adm_id,
					PatientID,
					EMPI,
					admission_date_time, 
					discharge_date_time, 
					admission_date,
					discharge_date,
					patientEncounterID,
					medicationTakenDTS,
					med_date,
					med_day,
					med,
					medtype,
					mednew,
					medname_mapped,
					route_mapped,
					Med_category,
					med_cat_num
			from meds2;
			quit;


** (2) Create ASE_2_0 dataset:  We only want ABX mednames that mapped to ASE 2.0 Sepsis;

	data ASE_2_0;
	set meds3 ;
	ASE_2_0=1;  /*create indicator variable*/
	where medname_mapped ne ' ';
	run;


*(2b) FOR ASE_2.0 DATASET; 
	data ASE_2_0a;
	set ASE_2_0;
	length medname_rt $35.;

			if ASE_2_0=1 then do;
				 if route_mapped='PO' then do;
					if med_category in ('antiviral', 'antimicrobial') then po_abx=1;
					if med_category in ('antifungal') then po_antifungal=1;
				 end; 

				 if route_mapped='IV' then do;
					if med_category in ('antiviral', 'antimicrobial') then iv_abx=1;
					if med_category in ('antifungal') then iv_antifungal=1;
				 end;    
			end;
		
		medname_rt=trim(compress(medname_mapped)||'_'||compress(route_mapped));
	run;



	/************/

*(2C) CREATE LIST OF DISTINCT MEDNAMES/ROUTES (for REF);

	proc sql;
	create table tmp.ase_2_0_medlist as
	select distinct med, medname_mapped,route_mapped, medname_rt, iv_abx, po_abx, iv_antifungal, po_antifungal
	from ASE_2_0a;
	quit;

/**(3)  CREATE FINAL OUTPUT datasets for ANTIMICROBIAL 
		based on 4 categories:  PO_abx  PO_antifungal  IV_abx  IV_antifungal 
		NOTE: ** for all-antibiotics dataset, use MED_TYPE variable (not med_category) 


				 CREATE FINAL DATASETS:     Transpose/Create Daily variables:
					•	Pressor_daily
					•	Antimicrobials
						o	IV abx
						o	IV antifungal
						o	PO abx
						o	PO antifungal
			******************************************************/




/*(3a):   ASE_2.0 */

			title 'data=ASE 2.0';
			proc freq data=ASE_2_0;
			tables medtype med_category med_cat_num  medtype*med_category/missing;
			run;

			data tmp.ase_2_0a;
			set ase_2_0a;
			if (po_abx=1 or iv_abx=1 or iv_antifungal=1 or po_antifungal=1) then antimicrobials_ase20=1;
			run;

				*before de-duplication, remove admission_date_time discharge_date_time patientEncounterID;
				data all_edw_ase_20_ ;
				set tmp.ase_2_0a;
				drop  admission_date_time discharge_datetime patientEncounterID;
				run;

					*limit to distinct records;
					proc sql;
					create table all_edw_ase_20 as
					select distinct * 
					from all_edw_ase_20_;
					quit;

						*[1/15/26] CREATE FINAL  DATASET TO SAVE TO TMP LIBRARY;
						**NOTE: values where ANTIMICROBIALS_ASE20=1 (includes abx, antifungals, antivirals) ;
						data tmp.antimicrobials_ase20;
							set all_edw_ase_20;
							where antimicrobials_ase20=1;
						run;



			/*Create TMP. datasets of iv/po exposed abx days  		*/

			proc sql;
				create table tmp.iv_abx_exposed_days as
				select distinct adm_id, patientID, empi, admission_date, discharge_date, 
								 medname_mapped,
								 med_date as medication_date, 
								 route_mapped, iv_abx
						from tmp.antimicrobials_ase20
						where iv_abx=1
						order by adm_id, patientID, medname_mapped, med_date;

				

				create table tmp.po_abx_exposed_days as
				select distinct  adm_id, patientID, empi, admission_date, discharge_date, 
								 medname_mapped,
								 med_date as medication_date, 
								 route_mapped, po_abx
						from tmp.antimicrobials_ase20
						where po_abx=1
						order by adm_id, patientID, medname_mapped, med_date;
			

				create table tmp.iv_antimicrobial_exp_days as
				select distinct  adm_id, patientID, empi, admission_date, discharge_date, 
								 medname_mapped,
								 med_date as medication_date, 
								 route_mapped, iv_abx, iv_antifungal
						from tmp.antimicrobials_ase20
						where iv_abx=1 or iv_antifungal=1
						order by adm_id, patientID, medname_mapped, med_date;

				create table tmp.po_antimicrobial_exp_days as
				select distinct adm_id, patientID, empi, admission_date, discharge_date, 
								 medname_mapped,
								 med_date as medication_date, 
								 route_mapped, po_abx, po_antifungal
						from tmp.antimicrobials_ase20
						where po_abx=1 or po_antifungal=1
						order by adm_id, patientID, medname_mapped, med_date;
			quit;




/***** VASOPRESSORS ********************/

/** (4) Create final Vasopressor datasets **/

			/**Note the distinction b/w:
			•	tmp.pressor (daily level)
				o	ea row for ea unique medname & date
				o	can be multiple rows per day;

			•	tmp.pressor_daily (daily-level)
				o	ea represents a single MRN/day, with multiple indicators for every pressor administred that day 
					(so 1+ pressor can be indicated on a single day)

*****************************************************************************************/


*Pull in Pressor dataset:  

*08/06/25;
data pressor;
set edw.Meds_allmgb_2021_2023_080525   ;
med_date=datepart(medicationTakenDTS);
format med_date YYMMDD10.;
where medtype='vasopressors';
run;


		*[08/16/25:  LImit to IV Pressors only - per v5 data spec ];
		data pressor1;
		set pressor;
		where adminRouteMapped='IV';
		run;



		proc sql;
		create table pressor2 as
		select  a.adm_id, 
				a.patientID, 
				datepart(b.hospitalAdmitDTS) 		as admit_date_hosp format mmddyy10.,  /*keep for ASE 1.0 */
				datepart(b.edArrivalDTS_derived) 	as admit_date_ed format mmddyy10., 
				min(calculated admit_date_hosp,calculated admit_date_ed) as admission_date format mmddyy10. label='start date of  hospitalization: min(edArrivalDTS_derived and admit_date_hosp)', 
				datepart(b.hospitalDischargeDTS) 	as discharge_date format mmddyy10.,
				b.admitLocation, b.dischargeLocation, a.*
		from pressor1 as a LEFT JOIN derived.Pop_episode_allmgb_2020_2024feb  as b
		on a.adm_id=b.adm_id;
		quit;


		*Limit to PRESSORS administered within admission-1 and discharge;
		data pressor3;
		set pressor2;
		where admission_date-1 le med_date le discharge_date;
		run;

				*QC:  check freq distribution;
				proc freq data=pressor4;
				tables year/missing;
				run;

		proc sql;
		create table pressor4 as
		select distinct  *, 
			med_date as pressor_date format mmddyy10.,
			mednameMapped, 
			adminRouteMapped as RouteMapped
		from pressor3;
		quit;

		*De-dupe:  remove hospital & patientEncounterID  (pts transferred to other hospitals may count pressor days more than once);
		proc sql;
		create table pressor5 as
		select 	distinct adm_id, patientId, empi, year(admission_date) as year, admission_date, discharge_date, 
				 admitLocation, dischargeLocation,
				pressor_date, 
				(pressor_date-admission_date)+1 as day,
				medNameMapped as med,
				routeMapped as route,
				1 as med_type

		from pressor4;
		quit;

title 'data=pressor5';
proc freq data=pressor5;
tables route year/missing;
run;


		
/* (5) CREATE FINAL PRESSOR DATASETS in TMP library:

	Note the distinction b/w:
	•tmp.pressor (daily level)
		o	ea row for ea unique medname & date
		o	can be multiple rows per day;

	•tmp.pressor_daily (daily-level w indicator variables)
		o	ea row represents a single MRN/day, with multiple indicators for every pressor administred that day (so 1+ pressor can be indicated on a single day)
	***************************************************************/

			/* SAVE AS FINAL DATASET  **/
			data tmp.pressor;
			set pressor5;
			run;


/***************************************************/
*CREATE PRESSOR_DAILY VBL;

	proc sql;
		create table pressor6 as
		select  adm_id, patientID, empi, admission_date, discharge_date, 
				admitLocation, dischargeLocation, 
				pressor_date as med_date , 
				day,
				med as  medname, 
				route, 
				med_type,  
				1 as pressor
		from tmp.pressor
		order by adm_id ,patientID, med_date, medname;
	quit;

/****/

	proc freq data=pressor6;
	tables medname/missing;
	run;

		data pressor7;
		set pressor6;

		if medname='PHENYLEPHRINE' 	then Phenylephrine=1; 	else Phenylephrine=0;
		if medname='EPINEPHRINE' 	then Epinephrine=1; 	else Epinephrine=0;
		if medname='NOREPINEPHRINE' then Norepinephrine=1; 	else Norepinephrine=0;
		if medname='VASOPRESSIN' 	then Vasopressin=1;		else Vasopressin=0;
		if medname='DOPAMINE' 		then Dopamine=1; 		else Dopamine=0;
		any_pressor=1;
		run;

			*calculate max value per day and collapse by day;
			proc sql;
			create table pressor8 as
			select 	distinct  adm_id, 
					patientID, med_date, day,
					max(phenylephrine) as Phenylephrine,
					max(epinephrine) as Epinephrine,
					max(norepinephrine) as Norepinephrine,
					max(vasopressin) as Vasopressin,
					max(dopamine) as Dopamine,
					any_pressor
			from pressor7
			group by adm_id, patientID, med_date
			order by adm_id, patientID, med_date;
			quit;


				/*[8/14/25]:  NOTE tmp.pressor_daily is now limited to IV pressors only*/
				data tmp.pressor_daily;
				set pressor8;
				run;
