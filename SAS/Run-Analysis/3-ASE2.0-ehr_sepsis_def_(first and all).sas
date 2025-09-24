/*******************************************************************************************************************
PROGRAM: 		3 ASE2.2  - ehr_sepsis_def_(first and all)															
                                                                 													
PURPOSE: 		Calculate sepsis variables using infection and organ dysfunction datasets			   			 	
		   		Output 2 final Sepsis datasets:  (1) FIRST_ASE: Limited to first-occuring ASE episode during encounter							
							   				 	 (2) ALL_ASE:  	Includes ALL ASE episodes, separated by <7 days apart (first CO-ASE vs. first-HO-ASE)	
							   				        		 and 14 days between subsequent HO-ASE events

AUTHOR:			Christina Chan
																		
DATE: 			9/22/25

INPUT Datasets:
					raw.basic
					sepsis.ehr_infection
 					sepsis.ehr_organ_dysfunction
					pop.pop_episode_allmgb_2020_2024feb

OUTPUT Datsets:			
					sepsis.ehr_sepsis_ase22_first
								-limited to the first-occurring ASE episode in an encounter (CO- or HO-ASE)
								-1 row per ASE episode / 1 row per encounter

					sepsis.ehr_sepsis_ase22_all
								-limited to ALL ASE episodes during encounter 
									 where CO and first HO-ASE separated by 7 days
									 and All subsequent HO-ASE's separated by 14 days
								-Each row represents a unique ASE episode /  There may be multiple rows per Encounter

					Merged to denominator dataset (allMGB 2022-20224feb)

REFERENCE: 
		** ORGAN DYSFUNCTION VARIABLES for ASE 2.0:

		vasopressor_min_day
		vasopressor_new
		hotn3
		hotn3_minday
		mechvent_min_day
		mechvent
		nivhfnc_minday
		nivhfnc
		lactate2_min_day
		lactate2
		Cr_new_COMM_min_day
		Cr_new_COMM
		Cr_new_HOSP_min_day
		Cr_new_HOSP
		tbili_new_COMM_min_day
		tbili_new_COMM
		tbili_new_HOSP_min_day
		tbili_new_HOSP
		Plt_new_COMM_min_day
		plt_new_COMM
		Plt_new_HOSP_min_day
		plt_new_HOSP
	
**********************************************************************************************************/

options nocenter pageno = 1 mprint macrogen;


*libname for FINAL;
libname tmp   'Z:\XXX\Reorganize Data v6.3\Tmp';
libname raw   'Z:\XXX\Reorganize Data v6.3\Output';
libname sepsis 'Z:\XXX\Run analysis\working datasets';



		%let basic 		 = basic;
		%let infection 	 = Ehr_infection  ;  			
		*%let bloodculture= Blood_culture_dxpoa_inf ; 	
		%let organdys 	 = Ehr_organ_dysfunction;    	
		%let asetype 	 = 2.2;    						

 
		%let abbv = 22;							
		%let outname = ase22	;			  


/************************************************************************************/
/* End of user inputs                                                               */
/************************************************************************************/


options nocenter pageno = 1 mprint macrogen;



/*(0)  PULL IN DATASETS ****************/

	* Pull in basic dataset;
	data basic_fnl;
	    set raw.&basic;
	run;

	*Pull in infection dataset;
	data infection;
	set sepsis.&infection;
	if infxn_onset_day <4 then co_inf=1; else co_inf=0;
	if infxn_onset_day >= 4 then ho_inf=1; else ho_inf=0;

	where infection=1;

	run ;

	*Pull in organ dysfunction dataset;
	  data  organ_dys;
	  set sepsis.&organdys;
	  run;




*(1) Merge Infection dataset to BASIC;

proc sql;
    create table basic_inf  as
    select distinct a.Adm_ID,
	               	a.patientID,
					a.admission_date, 
					a.discharge_date, 
					a.year, 
					a.hospital_id,
					"%str(&asetype.)" as asetype,
	               	coalesce(b.Infection, 0) as Infection,
					b.inf_qad4,  
					b.inf_qad3,  
					b.qad3_keep_enc,
					b.discharge_dispo, b.dd_group,
					b.blood_culture,
					b.bcx_drawn_day,
					b.dxpoa_inf_primary,
					b.infxn_anchor_day,
	               	b.QAD_first,
					b.infxn_onset_day,
					b.co_inf,
					b.ho_inf

       from basic_fnl a INNER JOIN 
            infection b
       on a.Adm_ID = b.Adm_ID and a.patientID = b.patientID;
quit;



*(2) Merge Organ Dysfunction to Infection;

proc sql;
    create table basic_inf_od  as
    select distinct a.*,
				c.od_any, 
				c.n_od,

               	coalesce(c.vasopressor_new, 0) as vasopressor_new,
               	c.vasopressor_min_day,

			    coalesce(c.hotn3, 0) as hotn3,
                c.hotn3_min_day ,  

			    coalesce(c.mechvent, 0) as mechvent,
                c.mechvent_min_day as mechvent_min_day,

			    coalesce(c.od_nivhfnc, 0) as nivhfnc,
                c.od_nivhfnc_min_day as nivhfnc_min_day,  

               coalesce(c.lactate2, 0) as lactate2,  
               c.lactate2_min_day,

               coalesce(c.Cr_new_comm, 0) as Cr_new_comm,
               c.cr_new_comm_min_day,  
               coalesce(c.Cr_new_hosp, 0) as Cr_new_hosp,
               c.cr_new_hosp_min_day,    
			  
               coalesce(c.tbili_new_COMM, 0) as tbili_new_COMM,
        	   c.tbili_new_comm_min_day,   
        	   coalesce(c.tbili_new_hosp, 0) as tbili_new_hosp,
        	   c.tbili_new_hosp_min_day,  	

               coalesce(c.Plt_new_comm, 0) as Plt_new_comm,
               c.Plt_new_comm_min_day,  
               coalesce(c.Plt_new_hosp, 0) as Plt_new_hosp,
               c.Plt_new_hosp_min_day        

        from basic_inf as a


        LEFT JOIN organ_dys as c
           ON a.Adm_ID = c.Adm_ID and a.patientID = c.patientID and
              a.infxn_anchor_day = c.infxn_anchor_day;
quit;

	

/***************************************************************************************
*(3) Apply Sepsis Logic to identify ASE ;


			** NOTES on timing of CO vs HO Sepsis (Updated Oct 2024 for ASE 2.0 & 2.1)/
			*  Updated 12/18/24 for ASE 2.0
				-ASE 2.0 CO-ASE:   any criteria met prior to hospital Day 4
				-ASE 2.0 HO-ASE:   ALL criteria met on hospital day 4 or later


				CO-ASE:  Any criteria met prior to hosp day 4
				•	blood culture/infxn_anchor_day + 
				•	first QADs + 
				•	organ dysfunction

				HO-ASE:    ALL 3 have to happen on hosp day 4 or later:
				•	blood culture/infxn_anchor_day + 
				•	first QADs + 
				•	organ dysfunction

				ALSO: Tweak to infection criteria that allows principal infection/sepsis diagnoses to trigger CO-infection 
					  if no blood culture drawn before day 4 (instead of day3) 
						--- BLOOD_CULTURE_DXPOA_INF & EHR_INFECTION datasets were both updated


				/* DEFINITIONS:
				“Presumed Infection Onset Day” = earliest of Infection_anchor_day or first QAD.  
				"Sepsis Onset Day” = earliest date where any criterion is met:  Infection Onset Day (earliest of first QAD, infxn_anchor_day)) 
				                      or organ dysfunction within window period where EHR definition is positive)  (ie,“date of sepsis event”=Sepsis Onset Day)

			*****************************************************************************************/


data  ehr_sepsis_def;	
    set basic_inf_od ;

	/* PRESUMED SERIOUS INFECTION **/

	    /* Hospital infection (must have 4 QAD's)*/
		    if (infection = 1 and inf_qad4=1 or (inf_qad3=1 and qad3_keep_enc=1))
				and infxn_anchor_day  >= 4 and QAD_first >= 4   /*DO NOT use infxn-onset-day b/c all 3 criteria must be >4 */
			then hosp_infection = 1;
		    else hosp_infection = 0;

	    /* Community infection (can include 4QAD's or discharged alive on QAD3) **/
		    if ((infection = 1 and inf_qad4=1) or (inf_qad3=1 and qad3_keep_enc=1 and blood_culture=1  and dxpoa_inf_primary=1) )  
				and infxn_onset_day < 4  
		
			then comm_infection = 1;
		    else comm_infection = 0;			



	/* COMMUNITY SEPSIS */

	if  (
			(comm_infection = 1 and n_od >= 1) and   
			 (infxn_onset_day <4 )  and

    		(  (vasopressor_new = 1 and vasopressor_min_day < 4) or
			   (hotn3=1 and hotn3_min_day  < 4) or

	           (mechvent = 1 and mechvent_min_day < 4) or 
     		   (nivhfnc=1 and nivhfnc_min_day < 4) or 

	           (lactate2 = 1 and lactate2_min_day < 4) or

	           (Cr_new_COMM = 1 and Cr_new_COMM_min_day < 4) or
	           (Cr_new_HOSP = 1 and Cr_new_HOSP_min_day < 4) or

	           (tbili_new_COMM = 1 and tbili_new_COMM_min_day < 4) or
	           (tbili_new_HOSP = 1 and tbili_new_HOSP_min_day < 4) or 

	           (plt_new_COMM = 1 and Plt_new_COMM_min_day < 4) or
	           (plt_new_HOSP = 1 and Plt_new_HOSP_min_day < 4)
	       )  
		 )   
		  OR

	 (
		(comm_infection = 1 and n_od >= 1) and   

	          (infxn_onset_day <4 ) and  
     	      (min(vasopressor_min_day, 
					hotn3_min_day, 
					mechvent_min_day, 
					nivhfnc_min_day,
					lactate2_min_day, 
					Cr_new_COMM_min_day, Cr_new_HOSP_min_day,
					tbili_new_COMM_min_day, tbili_new_HOSP_min_day,
					Plt_new_COMM_min_day, Plt_new_HOSP_min_day) >=4 )
	 )

 		OR
	(
		(hosp_infection = 1 and n_od  >= 1) and 

			(infxn_anchor_day >= 4 and QAD_first >= 4) and
			(min(vasopressor_min_day, 
					hotn3_min_day, 
					mechvent_min_day, 
					nivhfnc_min_day,
					lactate2_min_day, 
					Cr_new_COMM_min_day, Cr_new_HOSP_min_day,
					tbili_new_COMM_min_day, tbili_new_HOSP_min_day,
					Plt_new_COMM_min_day, Plt_new_HOSP_min_day) < 4)
	)

			 then comm_sepsis_&abbv. = 1;
			 else comm_sepsis_&abbv. = 0;



	  /* HOSPITAL SEPSIS */

	    if (hosp_infection = 1 and n_od  >= 1) and (infxn_anchor_day >= 4 and QAD_first >= 4) and

			(  	min(vasopressor_min_day, 
					hotn3_min_day, 
					mechvent_min_day, 
					nivhfnc_min_day,
					lactate2_min_day, 
					Cr_new_COMM_min_day, Cr_new_HOSP_min_day,
					tbili_new_COMM_min_day, tbili_new_HOSP_min_day,
					Plt_new_COMM_min_day, Plt_new_HOSP_min_day) >=4 
			)

			 then hosp_sepsis_&abbv. = 1;
			 else hosp_sepsis_&abbv. = 0;

	

    /* CREATE HOSPITAL/COMMUNITY VARIABLES */
    array hospvar (2)  hosp_infection hosp_sepsis_&abbv. ;
    array commvar (2)  comm_infection comm_sepsis_&abbv. ;
    array hospcomm (2) hospcomm_infection hospcomm_sepsis_&abbv.  ;

     do i = 1 to 2;
          hospcomm[i] = max(hospvar[i], commvar[i]);
     end;
run;



/***************************************************************************************************************************/
	/**[8/14/25]:  QC:  Add new definitions [CO_ASE & HO_ASE] that follow sepsis logic (to double check)  ;
	Sepsis Event Dates 
		Sepsis Event Window: +/-1 calendar day period around infection onset date 
		Sepsis Event Date: Earlier of infection onset date or qualifying organ dysfunction within the sepsis event window 
		Community-Onset Sepsis: event date <HD4 
		Hospital-Onset Sepsis: event date =HD4 

	NOTE:  These variables are for QC only - will be dropped from final dataset
	***********************************************************************************/

			data ehr_sepsis_def1;
			set ehr_sepsis_def;
				OD_minday = min(vasopressor_min_day, 
									hotn3_min_day, 
									mechvent_min_day, 
									nivhfnc_min_day,
									lactate2_min_day, 
									Cr_new_COMM_min_day, Cr_new_HOSP_min_day,
									tbili_new_COMM_min_day, tbili_new_HOSP_min_day,
									Plt_new_COMM_min_day, Plt_new_HOSP_min_day);
									
				if infection=1 and od_any=1 then do;
					sepsis_eventday = min(infxn_onset_day, OD_minday);
					label sepsis_eventday='Sepsis Event Day: Earlier of infxn_onset_day or OD_minday';

					sepsis_eventDT= (admission_date + sepsis_eventday) -1;
					format sepsis_eventDT mmddyy10.;

					*Define CO/HO Sepsis;
					if sepsis_eventday >= 4 then HO_ASE=1; 
					if sepsis_eventday <4 	then CO_ASE=1; 
				end;

			run;

			*QC;
			proc freq;
			tables   comm_sepsis_22 CO_ASE hosp_sepsis_22 HO_ASE   comm_sepsis_22*CO_ASE hosp_sepsis_22*HO_ASE/missing;
			run;
/***************************************************************************************************************************/




/**(4) LIMIT TO VARIABLES OF INTEREST
/*NOTE:  Focus on hospcomm_sepsis variable -- the FIRST row in an encounter where hospcomm_sepsis=1  ***/


						proc sql;
						create table Ehr_sepsis_def2 as 
						select 	distinct	adm_id,
									patientID,

									admission_date,
									discharge_date,
									year,
									hospital_id,
									asetype,

									co_inf, ho_inf,
									comm_infection, hosp_infection,
									hospcomm_sepsis_&abbv.,
									comm_sepsis_&abbv.,
									hosp_sepsis_&abbv.,

									HO_ASE, CO_ASE, 
									sepsis_eventday, sepsis_eventDT, 
									
									inf_qad4,
									inf_qad3,
									qad3_keep_enc,
									discharge_dispo, dd_group,
									bcx_drawn_day,
									dxpoa_inf_primary,
									infxn_anchor_day,
									QAD_first,
									infxn_onset_day,

									od_any,
									n_od,
									OD_minday, 

									vasopressor_new,
									vasopressor_min_day,

									hotn3,
									hotn3_min_day,

									mechvent,
									mechvent_min_day,

									nivhfnc,
									nivhfnc_min_day,

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
							
						from Ehr_sepsis_def1;
						quit;



		/**SAVE TO TMP DATASET
					==>  This is a Raw dataset of ALL ASE encounters... Interval spacing has NOT been applied yet */
				data tmp.ase_sepsis_&abbv._all;
				set Ehr_sepsis_def2;
				run;  
		



/**************************************************************************************************************************
**(5) Apply interval spacing between ASE events

				**  STEPS: If multiple ASE's per encounter, separate individual ASE's as follows:
					CO-ASE --> first HO-ASE  (7 days apart)  
					1st HO-ASE--> subsequent HO-ASE (14 days apart)


			 STEPS:
				-create 2 separate subsets:
					-Group A: First ASE is CO
					-Group B: FIrst ASE is HO
				
				-For group A, 
					-identify the first occurring HO-ASE (after 7 days)
					-Flag that case as first HO-ASE
					-Then create counter that calculates 14 days from first HO-ASE -- id all subsequent episodes with 14 day interval

				
				-For group B, 
					-Then create counter that calculates 14 days from first HO-ASE -- id all subsequent episodes with 14 day interval

				-THen recombine datasets;

**************************************************************************************************************************/



/**************************************************************/
/** (5A)  Create 2 separate subsets:
				-A: First ASE is CO
				-B: FIrst ASE is HO
***************************************************************/

data Ehr_sepsis_def3;
set Ehr_sepsis_def2; 
where hospcomm_sepsis_&abbv.=1  ;
run;

		proc freq;
		tables  co_inf comm_infection ho_inf hosp_infection/missing;
		run;

	data Ehr_sepsis_def3a;
	set Ehr_sepsis_def3;
			if comm_sepsis_22=1 then ase_type='CO';
			if hosp_sepsis_22=1 then ase_type='HO';
	run;

	proc sql;
	create table Ehr_sepsis_def3aa as
	select distinct *
	from  Ehr_sepsis_def3a;
	quit;

		*create LAG variable;
		proc sort data=Ehr_sepsis_def3aa;
		by adm_id  sepsis_eventday;
		quit;


			data ehr_sepsis_def3_all;
			set Ehr_sepsis_def3aa;
			by adm_id sepsis_eventday;

			/* Create a lagged variable for sepsis-type */
				lag_sepsis_eventday = lag(sepsis_eventday);
				lag_asetype = lag(ase_type);

			/* For the first observation of each patient, the lagged value should be missing */
			if first.adm_id then do;
				lag_sepsis_eventday = .;
				lag_asetype = ' ';
			end;

			/* Calculate the difference between the current and lagged values */
			Difference = (sepsis_eventday-lag_sepsis_eventday ) ;
			run;



				*ID first-occurring ASE;
					data z_ehr_sepsis_def3_all2;
					set ehr_sepsis_def3_all /*z_ehr_sepsis_def3_all*/;
					if Difference=. then ase_first=1;
					run;

				*Create indicators for first ASE (ho vs co) based on first-occurring ASE (CO vs. HO);
					data z_ehr_sepsis_def3_all3;
					set z_ehr_sepsis_def3_all2;
					if ase_first=1 and co_ase=1 then ase_first_co=1; 
					if ase_first=1 and ho_ase=1 then ase_first_ho=1;
					run;
							*create enc-level measure;
							proc sql;
							create table z_ehr_sepsis_def3_all4 as
							select *, 
									max(ase_first_co) as ase_first_co_enc,
									max(ase_first_ho) as ase_first_ho_enc
							from z_ehr_sepsis_def3_all3
							group by adm_id
							order by adm_id;
							quit;



**Create 2 subsets;
data z_ehr_sepsis_def3_all4_comm   z_ehr_sepsis_def3_all4_hosp;
set z_ehr_sepsis_def3_all4;
if ase_first_co_enc=1 then output z_ehr_sepsis_def3_all4_comm;
if ase_first_ho_enc=1 then output z_ehr_sepsis_def3_all4_hosp;
run;



/***********************************************************************************************/
/*(5B): ALLOW MULTIPLE ASE EPISODES (ea episode separated by 7 days);

	For group A,(first ASE is CO)
			-identify the first occurring HO-ASE (after 7 days)
			-Flag that case as first HO-ASE;
			-Then create counter that calculates 14 days from first HO-ASE -- id all subsequent episodes with 14 day interval

***********************************************************************************************/

	*create LAG variable;
	proc sort data= z_ehr_sepsis_def3_all4_comm ;
	by adm_id  sepsis_eventday;
	quit;



				data z_comm ;
			    set z_ehr_sepsis_def3_all4_comm ;
			    by adm_id sepsis_eventday;

			    /* RETAIN the last_ase_day for each encounter */
			    retain last_ase_day  ;

			    /* Reset DAYS_SINCE_LAST_ASEDAY  for the first record of each encounter */
			    if first.adm_id then do;
						days_since_last_aseday_reset=.;

						if ase_first_co=. and ase_first_ho=. then do;
					        last_ase_day = .;
							days_since_last_aseday=0;     ;
						end;
			    end;

			    /* Calculate the number of days since the previous ASE */
			    else do;
			        days_since_last_aseday =  sepsis_eventday  - last_ase_day;
			    end;

				/* Reset the counter if there are 7+ days between CO- and HO-ASE */
				if ase_type='HO' and lag_asetype='CO' and days_since_last_aseday ge 7 then  do;
					days_since_last_aseday_reset  = 0;
				end;

				else if ase_type='HO' and lag_asetype='HO' and (days_since_last_aseday ge 7 or   days_since_last_aseday_reset ge 7) then do;
						days_since_last_aseday_reset  = 0;
				end;

				    else do;
				        days_since_last_aseday_reset + days_since_last_aseday;
				    end;

			    /* Update the last_ase_day for the next iteration */
			    last_ase_day = sepsis_eventday ;
			run;


			*identify first occurring HO-ASE after CO-ASE (7 day interval);
			data z_comm1;
			set z_comm;
			if 	days_since_last_aseday_reset in (., 0)  or (days_since_last_aseday_reset ge 7) then flag_co2ho_ase=1;
			run;

			*create flag to identify first-HO_ASE with 7+ day interval bw CO==>  HO-ASE;
			data  z_comm2;
			set z_comm1;
			if ase_type='HO' and  flag_co2ho_ase=1 then co2ho_aseday = sepsis_eventday;
			run;

					proc sql;
					create table z_comm3 as
					select *, min(co2ho_aseday) as co2hoase_minday
					from z_comm2
					group by adm_id
					order by adm_id;
					run;


			*Create Flag that ID"s case as first HO-ASE;
					data z_comm4;
					set z_comm3;
					if co2hoase_minday = sepsis_eventday then flag_co2ho_first=1;
					drop difference days_since_last_aseday_reset days_since_last_aseday  last_ase_day co2ho_aseday;
					run;


	*NEXT create counter that calculates 14 days from first HO-ASE -- id all subsequent episodes with 14 day interval

		*create LAG variable;
		proc sort data= z_comm4 ;
		by adm_id  sepsis_eventday;
		quit;


				data z_comm5;
				    set z_comm4 ;
				    by adm_id ;

				    /* RETAIN the last_ase_day for each encounter */
				    retain last_ase_day ;

				    /* Reset DAYS_SINCE_LAST_ASEDAY for the first record of each encounter */
				    if first.adm_id then do;
							days_since_last_aseday_reset=.;

							if co2hoase_minday le sepsis_eventday  then  do;
						        last_ase_day = .;
								days_since_last_aseday=0;     ;
							end;
				    end;

				    /* Calculate the number of days since the previous ASE */
				    else do;
				        days_since_last_aseday =  sepsis_eventday  - last_ase_day;
				    end;

					/* Reset the counter if there are 14+ days between HO- and HO-ASE */		
				   if  (days_since_last_aseday > 14) or  (days_since_last_aseday_reset > 14) or flag_co2ho_first=1  then do;
							days_since_last_aseday_reset  = 0;
					end;
					    else do;
					        days_since_last_aseday_reset + days_since_last_aseday;
					    end;

				    /* Update the last_ase_day for the next iteration */
				    last_ase_day = sepsis_eventday ;
				run;

	 
	data z_comm6;
	set z_comm5;
	if  days_since_last_aseday_reset in (., 0) or days_since_last_aseday_reset ge 14 then keep=1;
	run;

			data z_comm7_final;
			set z_comm6;
			where  keep=1;
			run;



/***********************************************************************************************/
/*(5C): ALLOW MULTIPLE ASE EPISODES (ea episode separated by 14 days);
		For group B,(first ASE is HO)
			-Then create counter that calculates 14 days from first HO-ASE -- id all subsequent episodes with 14 day interval 
***********************************************************************************************/

*create LAG variable;
	proc sort data= Z_ehr_sepsis_def3_all4_hosp ;
	by adm_id  sepsis_eventday;
	quit;


			data z_hosp ;
			    set Z_ehr_sepsis_def3_all4_hosp ;
			    by adm_id sepsis_eventday;

			    /* RETAIN the last_ase_day for each encounter */
			    retain last_ase_day ;

			    /* Reset DAYS_SINCE_LAST_ASEDAY for the first record of each encounter */
			    if first.adm_id then do;
						days_since_last_aseday_reset=.;

						if ase_first_co=. and ase_first_ho=. then do;
					        last_ase_day = .;
							days_since_last_aseday=0;     ;
						end;
			    end;

			    /* Calculate the number of days since the previous ASE (DAYS_SINCE_LAST_ASEDAY)*/
			    else do;
			        days_since_last_aseday =  sepsis_eventday  - last_ase_day;
			    end;

				/* Reset the counter if there are 14+ days between HO- and HO-ASE */	
				 if ase_type='HO' and lag_asetype='HO' and (days_since_last_aseday ge 14 or   days_since_last_aseday_reset ge 14) then do;
						days_since_last_aseday_reset  = 0;
				end;

				    else do;
				        days_since_last_aseday_reset + days_since_last_aseday;
				    end;

			    /* Update the last_ase_day for the next iteration */
			    last_ase_day = sepsis_eventday ;
			run;


	data z_hosp2;
	set z_hosp;
	if days_since_last_aseday_reset in (., 0) or days_since_last_aseday_reset ge 14 then keep=1;
	run;


		data z_hosp3_final;
		set z_hosp2;
		where  keep=1;
		run;

	*Combine raw data with KEEP flag -- save for future reference;
	data z_hospcomm_all;
	set z_comm6 z_hosp2;
	run;

			proc sort data=z_hospcomm_all;
			by adm_id sepsis_eventday;
			run;

				data tmp.z_hospcomm_all;
				set z_hospcomm_all;
				run;


/***********************************************************************************************/
/*(5D):  Combine hosp and comm datasets;
***********************************************************************************************/

/** re-combine CO- and HO- ASE events as such:
    There must be >= 7 days between CO and HO sepsis events (based on date of sepsis event).  HO-sepsis events must be separated by >=14 days */

	data ehr_sepsis_def4_all;
	set z_comm7_final  z_hosp3_final;
	run;

			proc sort data=ehr_sepsis_def4_all;
			by adm_id sepsis_eventday;
			run;



	data ehr_sepsis_def4_all2;
	set ehr_sepsis_def4_all;
	drop bcx_drawn_day--qad_first lag_sepsis_eventday--difference;
	run; 


*(5E). KEEP EPISODE with earliest occurring infxn_onset_day;

	proc sql;
	create table ehr_sepsis_def4_all2_new as
	select distinct *, min(infxn_onset_day) as min_infxn_onset_day
	from ehr_sepsis_def4_all2
	group by adm_id, sepsis_eventday
	order by adm_id, sepsis_eventday;
	quit;

			*KEEP FIRST-OCCURRING infxn_onset_day for each  sepsis_eventday;
			data ehr_sepsis_def4_all2_new1;
			set ehr_sepsis_def4_all2_new;
			where infxn_onset_day =min_infxn_onset_day;
			run;



*(5F). KEEP FIRST-OCCURING EPISODE;


proc sql;
create table ehr_sepsis_def5_all as
select *, min(sepsis_eventday) as min_sepsis_eventday
from ehr_sepsis_def4_all2_new1
group by adm_id
order by adm_id;
quit;


	*keep first-occurring ASE event in encounter;
	data ehr_sepsis_def5_first;
	set ehr_sepsis_def5_all;
	where sepsis_eventday =min_sepsis_eventday;
	run;


*(6)*CREATE FINAL DATASETS;
	/*****************************************************************************************************************************/

	/***CREATE FINAL DATASETS;
	**This dataset is a daily-level dataset with each row representing a unique ASE encounter.  There may be multiple rows per encounter.
	  counts for CO vs. HO ASE are not mutually exclusive;

	*MACRO TO CREATE SEPSIS FINAL DATASET (will add to infection dataset;
	/** THis macro preps EHR_Sepsis dataset for merging to infection dataset (removes extra variables and re-orders)

	* createfinal macro:
		in=input dataset (EHR Sepsis)
		sfx= suffix for dataset (_first or _all_days)
		abbv = 22 (for ASE 2.2)
	**************************************/


%macro createfinal (in= , sfx= , abbv= );

							data ehr_sepsis_def5_&sfx.;
							set &in. ; 
							*drop lag_sepsis_eventday difference;
							run;

							proc sql;
							create table ehr_sepsis_fnl_&sfx. as
							select 	adm_id	,
									admission_date,
									asetype	,
									hospcomm_sepsis_&abbv.	,
									comm_sepsis_&abbv.,
									hosp_sepsis_&abbv.	,
									comm_infection,  hosp_infection,

									infxn_onset_day,
									od_any	,
									n_od	,
									od_minday	,
									sepsis_eventday	,
									(admission_date + sepsis_eventday)-1 as sepsis_eventDT format mmddyy10.,

									vasopressor_new	,
									vasopressor_min_day	,
									hotn3	,
									hotn3_min_day	,
									mechvent	,
									mechvent_min_day	,
									nivhfnc	,
									nivhfnc_min_day	,
									lactate2_min_day	,
									lactate2	,
									Cr_new_COMM_min_day	,
									Cr_new_comm	,
									Cr_new_HOSP_min_day	,
									Cr_new_hosp	,
									tbili_new_COMM_min_day	,
									tbili_new_COMM	,
									tbili_new_HOSP_min_day	,
									tbili_new_hosp	,
									Plt_new_COMM_min_day	,
									Plt_new_comm	,
									Plt_new_HOSP_min_day	,
									Plt_new_hosp	
							from   ehr_sepsis_def5_&sfx.;
							quit;
%mend;

*RUN MACRO FOR BOTH;
%createfinal (in=ehr_sepsis_def5_first, sfx= first,     abbv=22);
%createfinal (in=Ehr_sepsis_def5_all,   sfx=all_7d_14d , abbv=22);



/**********************************************************************************************************************/

/** (7) ADD INFECTION DATASET **/

	*Combine Comm_infection & comm_infection_qad3;
		proc sql;
		create table infection_all
		as select adm_id, patientID, 
				  comm_infection as comm_infection_, 
				  hosp_infection as hosp_infection_
		from ehr_sepsis_def;
		quit;

			*Take summarized value over ea encounter;
			proc sql;
			create table infection_enc_final as 
			select distinct adm_id, patientID,
							max(comm_infection_) as comm_infection,
							max(hosp_infection_) as hosp_infection ,
							max(calculated comm_infection, calculated hosp_infection) as hospcomm_infection 
			from infection_all
			group by adm_id
			order by adm_id;
			quit;

/****************************/
	*Merge to denominator dataset;

		*Pop_epi 2021-2023;
		libname pop 'Z:\Projects\CDC National Sepsis Surveillance - ASE variants\Data\EDW data refresh 2024\Data refresh 2024_CC\SAS datasets\derived';


		/*Add Raw infection data to denom:   use updated POP_EPISODE dataset for EDW refresh 2021-2024 */
			proc sql;
			create table pop_infection  as
			select  distinct 
					a.adm_id,
					a.patientID, a.episodeID,
					a.admission_date, a.discharge_date,
					a.empi, 
					a.hospital,
					a.admitLocation, 
					a.dischargeLocation,
					b.*
			
			from pop.Pop_episode_allmgb_2020_2024feb as a 	LEFT JOIN infection_enc_final as b
			on a.adm_id = b.adm_id ;
			quit;

/********************************************/

/*(8) Merge FINAL_SEPSIS to FINAL_INFECTION  */

	/**FINAL macro:  merges EHR_Sepsis to pop_infection
			in= name of input dataset (EHR_SEPSIS)
			out = name of output dataset (final sepsiss, merged to pop_infection)
			abbv=22 **/

%macro final (in= , out= , abbv=);

			proc sql;
			create table ase_finalfinal  as
			select 	a.*,b.*
			from pop_infection as a 	LEFT JOIN  &in. as b
			on a.adm_id = b.adm_id ;
			quit;


			*Reset values to zero;
				data &out.;
				set ase_finalfinal;
				array var{6} 	hospcomm_infection 			comm_infection 			hosp_infection  	   
								hospcomm_sepsis_&abbv.		comm_sepsis_&abbv.		hosp_sepsis_&abbv.	 ;

					do i=1 to 6;
					if var[i]=. then var[i]=0;
					end;
					drop i hospital_id year;
				run;

%mend;

*Run macro;
%final (in=Ehr_sepsis_fnl_first ,     out= z_ehr_sepsis_final_first, abbv=22);
%final (in=Ehr_sepsis_fnl_all_7d_14d , out= z_ehr_sepsis_final_all_7d_14d, abbv=22);



proc freq data=Z_ehr_sepsis_final_all_7d_14d;
tables 	hospcomm_sepsis_22 comm_sepsis_22  hosp_sepsis_22
		vasopressor_new	 
		hotn3	 
		mechvent	 
		nivhfnc	 
		lactate2	 
		Cr_new_comm	 
		Cr_new_hosp	 
		tbili_new_COMM	 
		tbili_new_hosp	 
		Plt_new_comm	 
		Plt_new_hosp/missing;
		where hospcomm_sepsis_22=1;
run;



/*(9)* SAVE TO PERM DATASET **************************************************************************************/

data sepsis.ehr_sepsis_ase22_first;
set z_ehr_sepsis_final_first;
run;

data sepsis.ehr_sepsis_ase22_all;
set z_ehr_sepsis_final_all_7d_14d;
run;


/*NOTE:  FINAL DATASET 1:  ehr_sepsis_ase22_first 	
		1-row per unique encounter;  limited to patients where hospcomm_sepsis=1 - and OD's reflect the FIRST episode of ASE
		e.g.,during encounter, a patient may have met different OD criteria on each day of hospitalization.  
		OD's captured in this dataset  reflect those occurring on the same day of  first day 
		of presumed serious infection (defined as blood culture and 4+ QAD's within +/- 1 days of BC/Infection_anchor_day);

		Merged to denominator dataset (allMGB 2015-2022)

		FINAL DATASET 2:  ehr_sepsis_ase22_all
		each row represents a unique ASE encounter per episode, so there may be more than 1 row per encounter

***********************************************************************************************************/



/** FINAL QC:  Merge to population/denominator dataset to assess counts for ASE incidence  ***********/
/** FINAL QC:  Merge to population/denominator dataset to assess counts for ASE incidence  ***********/


*QC for ASE_first dataset;

proc freq data=sepsis.ehr_sepsis_ase22_first;
tables hospcomm_infection hospcomm_sepsis_22/missing;
run;

proc freq;
tables hospcomm_infection*hospcomm_sepsis_22/missing norow nocol nopct;
run;

/****/
proc contents varnum data= sepsis.ehr_sepsis_ase22_first;
run;

/******/
proc sql;
create table test as 
select year(admission_date) as year, *
from   sepsis.ehr_sepsis_ase22_first;
quit;

	title1 "Final QC for EHR_SEPSIS_ASE22_FIRST dataset";
	title2 "NOTE: Data reflects FIRST ase episode only";

	proc freq;
	tables  year hospital 	hospcomm_infection	comm_infection 	hosp_infection 		n_od
			hospcomm_sepsis_22	comm_sepsis_22 	hosp_sepsis_22/missing;
	run;
	
/************************************/
proc sort data=test;
by  year hospital;
run;

/** QC:   Run freq distribution of ASE by year for each hospital
FINAL.EHR_SEPSIS_ASE21C dataset has 15 different hospital names
Array  hosp{15} BWF BWH CDH MCL MEE MGH MVH McL NCH NWH SCC SHC SLM SRH WDH *********/

*MACRO to output freq distribution of ASE*Year for all 15 hospitals in this dataset;
%Macro hello;
OPTIONS SYMBOLGEN MPRINT MLOGIC;
        proc sql noprint;
            select distinct hospital
            into :hosp separated by " "
            from test;
        quit ;
 
        %do i=1 %to %sysfunc(countw(&hosp));
            %let newhosp=%scan(&hosp,&i," ");
        
            title "&newhosp";
				proc freq data=test;
				tables  (hospcomm_sepsis_22 comm_sepsis_22   hosp_sepsis_22)*year/missing ;
				where hospital="&newhosp";
				run;
		%end;
%mend;

  %hello;


title 'N organ dysfunctions:  where hospcomm_sepsis=1';
proc freq;
tables n_od*(hospcomm_sepsis_22)/missing norow nocol nopct;
run;

title 'N organ dysfunctions:  where comm_sepsis=1';
proc freq;
tables n_od*(comm_sepsis_22)/missing norow nocol nopct;
run;

