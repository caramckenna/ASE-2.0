/**************************************************************************

*filename: 	02.0-final_enc_dataset

*Created:	9/18/25

*By:		Christina Chan


*Purpose:	Combine Encounters data with Mapped medications data
			(precursos to BASIC dataset)

			Read in Primary Inpatient Encounters dataset
			 -Limit to encounters for which there is an antimicrobial prescribed
			    b/w admit and discharge_dates
			 -Identify and remove repeat encounter rows (or with different discharge dates) 

INPUT:
				derived.Pop_episode_allmgb_2020_2024feb   
				tmp.iv_antimicrobial_exp_days 
				tmp.po_antimicrobial_exp_days

OUTPUT:
				tmp.all_antimicrobial 
				tmp.admit_discharge 
				raw.encounters


	NOTES ON FINAL EHR DATASET:

	1.  EHR Clinical Data Starting Point: All inpatients who received a systemic antibiotic, antifungal, or antiviral (PO or IV) for =< 1 calendar day. 
		If a patient was only seen in the ED and was never admitted, but received antibiotics, they should be included if they died in the ED.

		For all patients, data should be provided for their ED stay (if applicable) as well as their inpatient hospitalization.  

**********************************************************************************************************/


*v6.3 (EDW data refresh 2024);;
libname edw 'xx ';
libname derived 'yyy';

*Libname for All Meds (pressors & abx) - merged to inpatient population;
libname ase 'Z:\xxx\Data refresh 2024\SAS datasets';

*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';







*Pop_episode dataset(allmgb_2020_2024feb) includes encounters from 12/01/20 and 1/31/24 ;


	proc sql;
	create table edw_enc as
	select  adm_id label='ID for total pop',
			patientID,  empi,
			hospitalAdmitDTS,
			datepart(hospitalAdmitDTS) as admit_date_hosp format mmddyy10.,  /*keep for ASE 1.0 */
			edArrivalDTS_derived,
			datepart(edArrivalDTS_derived) as admit_date_ed format mmddyy10., 
			min(calculated admit_date_hosp,calculated admit_date_ed) as admission_date format mmddyy10. label='start date of  hospitalization: min(edArrivalDTS_derived and admit_date_hosp)', 
			datepart(hospitalDischargeDTS) as discharge_date format mmddyy10.,

			admitLocation, dischargeLocation,
			encAge	as	age	,
			sex	as	gender	,
			raceGroup,
			dischargeDisposition	as	discharge_dispo	,
			dischargeDispositionGroup as dd_group,

			birthDT	as	dob	,
			deathDT	as death_date,
			deathDTS_derived 

    from derived.Pop_episode_allmgb_2020_2024feb   

	where adm_id ne .;
	quit;



/**	For all patients in EHR dataset, want to include data on ED stay (if applicable)
	as well as their inpatient hospitalization;
    NOTE: Sepsis Algorithm will only include INPATIENTS & ED Patients who died before admission ****/



/*(2) DEDUP (some records are listed in duplicate, triplicate, 8x....  
	  the only difference is in edPResentingComplaint (lengthy entries that exceed textstring limit ) ***/
proc sql;
create table  all_enc2 as
select distinct *
from edw_enc;
quit;



/* (3) Select encounters for which there is an antimicrobial prescribed between the admit_date and discharge_date */
/*     This is taken in from the cleaned medications files, which need to be generated beforehand */


/***(3A) for ASE_2.0:  'microbials' includes antibiotics, antivirals, antifungals;   iv_abx/po_abx includes antibiotics & antivirals **/
		data tmp.all_antimicrobial;
			set tmp.iv_antimicrobial_exp_days tmp.po_antimicrobial_exp_days;
		run;

			proc sql;
			create table all_antimicrobial2 as
			select distinct adm_id, patientID, medname_mapped as medname, medication_date, route_mapped as route, iv_abx, po_abx,  iv_antifungal, po_antifungal
			from tmp.all_antimicrobial;
			quit;


		/* Select encounters for which there is an antimicrobial prescribed between the admit_date 
			and discharge_date */
		proc sql;
			create table tmp.admit_discharge as
			select distinct a.*
			from  all_enc2  as a INNER JOIN  all_antimicrobial2 as b
				on a.adm_id=b.adm_id
			where (a.admission_date <= b.medication_date <= a.discharge_date)
			order by a.patientID, a.admission_date, a.discharge_date;
		quit;


			proc sort data=tmp.admit_discharge;
				by adm_id patientID admission_date discharge_date ;
			run;


		/*Look for repeat encounter rows (or with different discharge dates */

			*[collapse to encounter level];
				proc sql;
				create table admit_discharge_meds as
				select distinct *
				from tmp.admit_discharge;
				quit;


				**Create indicator to ID repeat encounters;
				data admit_meds;
					set admit_discharge_meds;
					by  patientID admission_date;
					retain discharge_count;
					if first.admission_date then discharge_count=1;
					else discharge_count=discharge_count+1;
				run;


				/**NOTE: IF DISCHARGE_COUNT =1 FOR ALL RECORDS then save as "raw.encounters" (otherwise investigate further) ***/
				proc freq data=admit_meds;
				table discharge_count/missing;
				run;


						*SAVE AS FINAL ENCOUNTERS DATA;

								data raw.encounters;
								set admit_meds;
								run;
