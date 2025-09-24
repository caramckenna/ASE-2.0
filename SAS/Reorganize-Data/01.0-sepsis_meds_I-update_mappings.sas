
/***************************************************************************************
PROGRAM:	01.0-sepsis_meds_I-update_mappings

DATE:			09/18/25 - Run with updated EDW meds (raw format)

CREATED BY:		Christina Chan



INPUT DATASETS:
			derived.Meds_allmgb_2021_2023_080525
					-->  raw medications data
		
			Med Mappings:  map.ase_med_mappings_011525;
					-->  Mapped Mednames - available as CSV download on GIT


OUTPUT DATASETS

	meds.mapped_meds_allMGB_2015_2022dec;
		-->  This is all antibiotics/antivirals/antifungals (daily-level) for allMGB 2015-2022dec, merged to Pop_episode_allMGB;
		    It is a daily-level dataset (ea row represents unique medname/day);  includes mapped mednames and indicators for:
				-ASE 2.0 sepsis algorithm

	tmp.final_mapped_EDWmeds
		-->  This is a final list of all DISTINCT mednames /routes (along with mapped medname) in the dataset: Mapped_meds_allMGB_2015_2022


PURPOSE:  	Prepare raw medications dataset for input into EHR Sepsis Algorithm:
 			Apply mappings for standardized  medication names 

NOTES:	
			- Vasopressor medication type includes IV norepinephrine, epinephrine, phenylephrine, dopamine, and vasopressin
			- Systemic antibiotics include antibacterials, antifungals, and antivirals.  


STEPS:	-Pull in raw Medications data 
		-Incorporate minor changes to MedNames and routes (clean up from past and present)
		-create list of unique mednames/routes (for mapping)
		-Merge to Medication mappings
		-Identify new mednames that need to be mapped
		-Create updated mappings for Mednames
		-Merge to *updated* mapping file 

		-Then merge updated mappings to FULL EDW meds dataset
				-->  Save to PERM dataset:   mapped_meds_allMGB_2015_2022


	*************************************************************************************/


*[8/6/25]:  Libname for All Meds (pressors & abx) - merged to allMGB_pop_episode_2015-2023;
libname ase 'xx';
libname derived 'yy';

*libname for TMP datasets (6/17/25);
libname tmp 'xx\Reorganize Data\Tmp';


proc sql;
create table meds_allMGB  as 
select 	adm_id, 
		patientiD, empi,
		admission_date_time, discharge_date_time, 
		medicationTakenDTS,
		medicationTakenDT ,
		patientEncounterID, 
		mednameMapped as med,
		adminRouteMapped as route,
		adminRouteMapped as route_abx ,
		medtype
		
	from derived.Meds_allmgb_2021_2023_080525;
	quit;

/** LIMIT MEDS DATASET to  antibiotics & antifungals/virals,    *******/


	proc sql;
	create table edw_meds  as 
	select 	*
	from meds_allMGB
	where medtype in ('antibiotics', 'antiviral_antifungal');
	quit;


	proc freq;
	tables medtype/missing;
	run;

		proc sort data=edw_meds;
		by adm_id medicationTakenDT;
		run;


/***********************************************************************************************
(2) Assess changes to make to EDW Meds dataset;
	-Create lookup dataset (unique mednames from EDW Meds data) & merge to  Medname Mappings;
	-Identify new mednames in updated EDW data that do not match to mappings
	-then update Medname Mappings - (where we exclude specific med names that should not
									be considered for the sepsis algorithm) 
	-and additional programming (as needed) to incorporates manual changes 

************************************************************************************************/

*(2A) create list of unique mednames/route (for general eyeball view - assess if there are new med names;
		*NOTE:  This list is merged to Mapped MedNames.  Merged list is used to ID new mednames that need to be mapped;
				proc sql;
				create table edw_medlist_pre as
				select distinct med, medtype, route
				from edw_meds
				order by med, medtype;
				quit;


			*(2B) INCORPORATE MANUAL CHANGES TO MEDS DATA;

				*(A) [RESET MED ROUTE:] For antibiotics/antifungals, if ROUTE=IM or missing, then reset to IV ;
				**Remove INHALED antibiotics;
				data edw_meds2;
				set edw_meds;
				if route='INHA' then delete;
				route_new=route;
				route_abx_new=route_abx;
						if route in (' ','IM' ) then route_new='IV';
						if route_abx in (' ','IM') then route_abx_new='IV';
				    
				run;

				*(B) [4/3/23] Incorporate manual changes to Mednames & Routes
						(only applies to ERH sepsis algorithm for allMGB medications 2015-2022);
						data edw_meds2a;
							set edw_meds2;

							if med='ACYCLOVIRÂ IVPB' then med='ACYCLOVIR';
							if med='AMPHOTERICIN-B' then med='AMPHOTERICIN B'; 


							if route_new='NA' and med='PENICILLIN' then do;
								route_new='IV';
								route_abx_new='IV';
							end;


						run;


					*(C) [8/22/22]: INCORPORATE CHANGES discovered AFTER merging EDW Meds data with Mapping document ;
					data edw_meds3a;
					set edw_meds2a ;
					med2=med;
					if med='BARICITINIB STUDY DRUG'  then med2='BARICITINIB';
					if med='BRINCIDOFOVIR STUDY DRUG' then med2='BRINCIDOFOVIR';
					if med='CASPOFUNGIN STUDY DRUG'  then med2='CASPOFUNGIN';
					if med='REMDESIVIR STUDY DRUG' then med2='REMDESIVIR';
					if med='TOCILIZUMAB STUDY DRUG'  then med2='TOCILIZUMAB';


					run;


					*(D) *Clean standardize mednames: replace /, -, ' ' with '_''  */;
						data edw_meds3b;
							set edw_meds3a ;
								length word $1  mednew $29. ;
								mednew=med2;
							do word= ' ', '/', '-';
								mednew = tranwrd(strip(mednew) ,word, '_');
							end;
							drop word med2;
						run;


	*(3) import list of Mapped Mednames to include in ASE 2.0 DEFINITION ; 

		libname map 'Z:\Projects\CDC National Sepsis Surveillance - ASE variants\Admin\mappings';

		data med_mappings;
		set map.Ase2_med_mappings_062625;
		med_name=upcase(med_name);
		run;



  *(4) Merge MAPPED_SEPSIS_MEDS (updated 6/26/23) to full EDW_MEDS;

			data edw_meds4;
			set edw_meds3b;
			drop route route_abx ;
			run;

			  /*Merge MED to PopEPiMap (want admission_date to calculate med_day);
					*Add admission_date from Pop_episode datsaet;
						
				  In [derived.Pop_episode_allmgb_2020_2024feb], admission_date variables are calculated as:
							   admit_date_hosp = datepart(hospitalAdmitDTS) - inpatient admission date
							   admit_date_ed = datepart(edArrivalDTS_derived) - ED admission date (if applic)
							   admission_date= min(admit_date_hosp, admit_date_ed)  
				******************************************************/

				 proc sql;
				create table pop_episode as
				select distinct a.adm_id, 
								a.patientID, 
								a.empi, 
								b.admit_date_hosp, /* include for ASE 1.0  */
								a.discharge_date, 
								b.edArrivalDTS_derived, 
								datepart(b.edArrivalDTS_derived) as admit_date_ed format mmddyy10. 

				from derived.Popepimap_121124 as a LEFT JOIN derived.Pop_episode_allmgb_2020_2024feb as b
				on a.adm_id=b.adm_id;
				quit;


			proc sql;
				create table edw_meds5 as
				select distinct a.adm_id, 
					  min(b.admit_date_hosp, b.admit_date_ed) as admission_date format mmddyy10. label='start of hospitalization: min of edArrivalDTS_derived and admit_date_hosp',
					  b.admit_date_hosp,
					  b.admit_date_ed,
					  b.edArrivalDTS_derived, 
					  b.discharge_date, 
					  a.*
				from edw_meds4 as a LEFT JOIN pop_episode  as b
				on a.adm_id=b.adm_id;
				quit;


				proc sql;
				create table edw_meds5_mapped as
					select 	distinct a.*, 
							b.med_name as medname_mapped, 
							b.route as route_mapped,
							b.med_category, 
							b.med_cat_num
				from   edw_meds5 as a LEFT JOIN med_mappings  as b
				on  a.mednew=b.med_name and a.route_new =b.route;
				quit;

	/*(7) SAVE TO PERM DATSAET *********************************/

		 	DATA derived.mapped_meds_allMGB_2021_2023;
			set edw_meds5_mapped;
			run;


/******************************************************/	

			*Final list of DISTINCT mednames (from EDW), with associated mappings;
			title1 'Final list of mapped mednames';
			title 'abx, antifungals, antivirals medTakenDT';

			proc sql;
			select distinct mednew, route_new,  medtype, medname_mapped, med_category, med_cat_num
			from derived.mapped_meds_allMGB_2021_2023;
			quit;


			proc contents varnum data= derived.mapped_meds_allMGB_2021_2023;
			run;

			proc freq;
			tables medname_mapped medtype med_category/missing;
			run;


