/* FILENAME: 		04.0-final med dataset
/* DATE: 			6/7/18 for ASE 1.0 v3;
					08/13/25:  Update section on VASOPRESSORS:     tmp.pressor_daily dataset is NOW limited to IV routes only
					09/08/25:   Re-run using updated tmp.pressors dataset (raw data combined with original PopEpisode datasset)

/* PURPOSE: 		Create final medications dataset

/* INPUT DATASETS:	tmp.pressor_daily
					tmp.iv_antimicrobial_exposed_days
					tmp.po_antimicrobial_exposed_days

					raw.basic

/* OUTPUT DATASET:  raw.medications

/********************************************************************************************************************************/

*Filepath for population datasets (population datasets for allMGB EDW - daily & encounter-level);
*v6.3 (EDW data refresh 2024);;
libname edw 'xx ';
libname derived 'yyy';


libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';


		data medications;
			set tmp.pressor_daily(rename=(med_date=medication_date) in=pressors_) 
				tmp.iv_antimicrobial_exp_days (drop=route_mapped rename=(medname_mapped=iv_antimicro) in=iv_anti_)
				tmp.po_antimicrobial_exp_days (drop=route_mapped rename=(medname_mapped=po_antimicro) in=po_anti_);
			drop _NAME_;
			length med $ 29;
			if phenylephrine = 1 then med = "PHENYLEPHRINE";
			if epinephrine = 1 then med = "EPINEPHRINE";
			if norepinephrine = 1 then med = "NOREPINEPHRINE";
			if vasopressin = 1 then med = "VASOPRESSIN";
			if dopamine = 1 then med = "DOPAMINE";

			if iv_abx ne . then med = iv_antimicro;
			if iv_abx ne . then route = "IV";

			if iv_antifungal ne . then med=iv_antimicro;   
			if iv_antifungal ne . then route="IV";			

			if po_abx ne . then med = po_antimicro;
			if po_abx ne . then route = "PO";

			if po_antifungal ne . then med = po_antimicro;	
			if po_antifungal ne . then route = "PO";		

			if patientID ne "";
			if pressors_ = 1 then med_type = 1;
			if iv_anti_ = 1 | po_anti_ = 1 then med_type = 2;

		run;

			proc sort;
			by adm_id;
			run;
	

		/*** pull in BASIC dataset ***/
				data basic ;
				set final.basic ;
				run;

				proc sort data=basic ;
					by adm_id;
				run;

		/** Merge to med data by adm_id   **/

		proc sql;
			create table final_meds as
			select a.adm_id,  a.patientid, a.admission_date,  a.discharge_date, 
			b.medication_date,
			(b.medication_date-a.admission_date) +1 as day label='med_day, relative to admission_date (ASE 2.0)' ,
			b.med, b.route, b.med_type

			from basic as a LEFT JOIN medications as b
			on a.adm_id = b.adm_id & a.admission_date-1 <= b.medication_date <= a.discharge_date;
		quit;

		proc sort data=final_meds;
			by adm_id patientid admission_date discharge_date med medication_date;
		run;

	*[8/31/22]: Create separate mednames for Vancomycin_po vs. Vancomycin_iv;
		data final_meds2;
		set final_meds;
			if med='VANCOMYCIN' then do;
				if route='IV' then med='VANCOMYCIN_IV';
				if route='PO' then med='VANCOMYCIN_PO';
			end;

		run;

		proc sort data=final_meds2;
			by adm_id patientid admission_date discharge_date med medication_date;
		run;

		data medications_finalfinal;
			set final_meds2;
			by adm_id patientid admission_date discharge_date med medication_date;
			if first.medication_date;
		run;

		  
		*SAVE AS FINAL;
		data final.medications;
		set medications_finalfinal;
		run;




