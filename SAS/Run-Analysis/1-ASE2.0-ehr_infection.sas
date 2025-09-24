/****************************************************************************************************************************************************************
* PROGRAM: 	1-ASE2.0-EHR_Infection

* PROGRAMMER:   Christina Chan
*                                                                         							
* Purpose:   Calculates infection cases in Sepsis dataset using   	                                                     
* 			 blood_culture_dxpoa_inf, medications, & basic datasets                                                                   	

* DATE:     11/27/2024   

*           12/17/24 for ASE 2.1a:  Create updated macro %QADENC_LT4_CCNEW replaces old macro(%qad4_lt4) 
    					For cases with fewer than 4 QADs, include if death, hospice, tx to acute care hospital, OR TRANSITION TO COMFORT CARE within 1 day
    					[Transition to comfort care is new... previously, only counted if comfort care was ordered on same abx day)

*           12/23/24 for ASE 2.1c (2015-2022):   Add tweak that refines QAD3 cases (patients with <4QADs's who were discharged ALIVE on QAD3)

*           08/11/25:  Add new changes per updated Data Spec (v5) from 8/10/25:
        				- add recode for infection_onset_day == min(qad_first, infxn_anchor_day)
        				- Define infxn_anchorday based on dxpoa_inf_primary and blood culture drawn day(s):  
        				- For cases where <4 QAD's are allowed & where consec antibiotic days fall within infection window & if dc_disposition=death/hospice 
        					or if comfort_care_day is within 1 day of last QAD

*           08/13/25: Limit blood culture data records where BCX_DAY falls between admission & discharge (formerly admit-2 and discharge)
*           08/15/25: Include all clinical data from one calendar day before admission (ie, admit-1 or hospital day 0) & discharge
														(formerly admit-2 and discharge)
*           08/17/25 -  Add recode to ID records with QAD3(dc alive) or <QAD4 that do not qualify for infection 
*           08/25/25:  Add deathDT (for infection cases with <4QAD's)
*           09/03/25:  Tweak to code that in section that identifies QAD's (for cases where subsequent QADs can be different antibiotics
                     as long as the first dose of each is “new” )

******************************************************************************************************************************************************************/



*libname for FINAL;
libname tmp   'Z:\XXX\Reorganize Data v6.3\Tmp';
libname raw   'Z:\XXX\Reorganize Data v6.3\Output';
libname final 'Z:\XXX\Run analysis\working datasets';


/* The names of the datasets and been pre-filled below.  Make changes as necessary 
	to match the names of datasets you've placed in the Raw folder */

/* Basic dataset name */
%let basic = basic;

/* Name of dataset with all blood cultures */
%let bloodculture = Blood_culture_dxpoa_inf; 


/* Medication dataset name */
%let medication = medications   ;


/***/

%macro delete_ds(dslist);
    proc datasets library = work nolist;
        delete &dslist.;
    quit;
%mend delete_ds;


%macro delete_ds2(dslist2);
    proc datasets library = tmp nolist;
        delete &dslist2.;
    quit;
%mend delete_ds2;


options nocenter pageno = 1 mprint macrogen;




* I.  Create basic dataset;

proc sql;
create table basic1 as 
select  *
from raw.&basic ;
quit; 



	/* THIS CODE Counts ANY patient that started out in ED as encounter-type=E:   */
	/*NOTE:   Patients starting out in ED & admitted as inpatient are filtered out using specific ED_discharge status */
		data basic_fnl;
		    set basic1;
			discharge_day=(discharge_date-admission_date)+1;

			*Create variable that distinguishes b/w Inpatient and ED only (admit_date_ed = datepart(edArrivalDTS);
			if admit_date_ed ne . then encounter_type='E';
			else encounter_type = 'I';

		run;



/** II.  PULL IN BLOOD CULTURE/ DXPOA_INFECTION_PRINCIPAL_DX     ***********************/
/**			Can use BLOOD_CULTURE_DXPOA_INF dataset -- or can LIMIT to records with: (a) no blood culture but dxpoa_inf_primary=1 -OR- (b) blood_culture=1 and bcx_drawn_day ge 1  */

	data bloodculture_dxpoa_fnl;
	set raw.Blood_culture_dxpoa_inf;
	where (blood_culture=0 and dxpoa_inf_primary=1) | (blood_culture=1 and bcx_drawn_day ge 0);
	run;



/**************************************************************************************************************************************/
/** III. MEDICATIONS DATA ******/
/**  Confirm that DAY variable in meds dataset accurately reflects (med_date-admission_date)+1 **/


	* PREP MEDICATIONS DATASETS;
	* limit clinical data to meds starting at hosp day 0 (admit-1);

	proc sql;
	    create table antibiotic_raw1 as
	        select distinct Adm_ID,
	                        PatientID,
	                        upcase(Med) as Antibiotic length = 32,
	                        Route,
	                        Day
	        from raw.&medication 
			where med_type=2 and Day ge 0;    /** NOTE:  limiting to antibiotics only - exclude pressors */
	quit;





/** IV. MEDICATIONS DATA:  Determine QADs ******/


proc sql;
    create table antibiotic_qad1 as
        select distinct a.Adm_ID,
                        a.PatientID,
                        a.infxn_anchor_day, 
                        b.Antibiotic,
                        b.Route,
                        b.Day
         from bloodculture_dxpoa_fnl    a,
              antibiotic_raw1  b
         where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID;
quit;




%delete_ds(dslist = antibiotic_raw1);

** Separate antibiotic data for cases with antibiotic = VANCOMYCIN;

data antibiotic_qad2 antibiotic_qad_van1;

    set antibiotic_qad1;

    /* Rename antibiotics with non alphabetic characters, replace non-alphabetic characters with [_] */

    ab_len = length(antibiotic);
    antibiotic = prxchange("s/\W/_/o", -1, antibiotic);
    do i = ab_len+1 to 32;
        if i > ab_len then substr(antibiotic,i,1) = ' ';
    end; 
    if antibiotic =: "AMPHOTERICIN_B" then antibiotic = "AMPHOTERICIN_B";

    if antibiotic = "VANCOMYCIN_PO" then antibiotic = "VANCOMYCIN";
    if antibiotic = "VANCOMYCIN_IV" then antibiotic = "VANCOMYCIN";

    if antibiotic ^= 'VANCOMYCIN' then output antibiotic_qad2;
    else output antibiotic_qad_van1;
run;

%delete_ds(dslist = antibiotic_qad1);

/* Create a subset of antibiotic data */
proc sql;
    create table antibiotic_qad3 as
        select distinct Adm_ID,
                        PatientID,
                        Antibiotic,
                        Day
        from antibiotic_qad2
        order by Adm_ID, PatientID, Antibiotic, Day;
quit;



/* Determine if antibiotic has been administered in previous 2 days */
/* and if a gap of 1 day exists between antibiotics                 */
data antibiotic_qad4;
    set antibiotic_qad3;
    by Adm_ID PatientID antibiotic;
    diff = ifn(first.antibiotic = 0, Day - lag(Day), .);
    if first.antibiotic then do;
         antibiotic_new = 1;
    end;
    else do;
        if diff > 2 then antibiotic_new = 1;
        else antibiotic_new = 0;

    end;
run;





%delete_ds(dslist = antibiotic_qad3);

/* Combine variables for new antibiotic with original data */
proc sql;
    create table antibiotic_qad5 as
            select a.*,
                   b.antibiotic_new
        from antibiotic_qad2 a
        LEFT JOIN antibiotic_qad4 b
            ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
               a.Antibiotic = b.Antibiotic and a.Day = b.Day;
quit;





%delete_ds(dslist = antibiotic_qad2 antibiotic_qad4);

/* Determine if vancomycin is new and if a gap of 1 day exists between vancomycin for */
/* a route                                                                            */

/* Create a subset of antibiotic data */
proc sql;
    create table antibiotic_qad_van2 as
        select distinct Adm_ID,
                        PatientID,
                        Antibiotic,
                        Route,
                        Day
        from antibiotic_qad_van1
        order by Adm_ID, PatientID, Antibiotic, Route, Day;
quit;

data antibiotic_qad_van3(drop = diff);
    set Antibiotic_qad_van2;
    by Adm_ID PatientID Antibiotic Route;
    diff = ifn(first.route = 0, Day - lag(Day), .);
    if first.route then do;
        antibiotic_new = 1;
    end;
    else do;
        if diff > 2 then antibiotic_new = 1;
        else antibiotic_new = 0;
    end;
run;

%delete_ds(dslist = antibiotic_qad_van2);

/* Combine variables for new antibiotic with original data for VANCOMYCIN */
proc sql;
    create table antibiotic_qad_van4 as
            select a.*,
                   b.antibiotic_new
        from antibiotic_qad_van1 a
        LEFT JOIN antibiotic_qad_van3 b
            ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
               a.Antibiotic = b.Antibiotic and a.Route = b.Route and a.Day = b.Day;
quit;

%delete_ds(dslist = antibiotic_qad_van1 antibiotic_qad_van3);

/* Combine non-VANCOMYCIN and VANCOMYCIN antibiotic results */
data antibiotic_qad_all1;
    set antibiotic_qad5 antibiotic_qad_van4;
run;

%delete_ds(dslist = antibiotic_qad5 antibiotic_qad_van4);


/* UPDATE for ASE 2.0: New IV antibiotic within the +/-1 day window */
/* Find new antibiotics within +/- 1 day surveillance window of blood culture/infxn_anchor_day */

proc sql;
    create table antibiotic_qad_all2_NEW as
        select distinct a.Adm_ID,
                        a.PatientID,
                        a.infxn_anchor_day ,
                        b.Antibiotic,
                        b.Antibiotic_new,
                        b.Route,
                        b.Day
         from bloodculture_dxpoa_fnl  a,
              antibiotic_qad_all1 b
         where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
               a.infxn_anchor_day = b.infxn_anchor_day  and 
               b.antibiotic_new = 1 and -1 <= a.infxn_anchor_day - b.Day  <= 1
         order by Adm_ID, PatientID, infxn_anchor_day, Day;
quit;


	/*Limit to *NEW* IV antibiotic within the +/-1 day window  */
	data antibiotic_qad_all2_NEW_IV;
	set antibiotic_qad_all2_NEW;
	where route='IV';
	run;



/* Find 1st QAD for IV antibiotic that is new by Admission_ID, patientID, infxn_anchor_day  */
data antibiotic_qad_first_new;
    set antibiotic_qad_all2_NEW_IV;
    by Adm_ID PatientID infxn_anchor_day  ;
    length antibiotic_first $40.;
    if first.infxn_anchor_day;
    Day_min = Day;
    antibiotic_first = antibiotic;
run;

%delete_ds(dslist = bloodculture_draw antibiotic_qad_all2);

/* Find antibiotics other than VANCOMYCIN occuring after 1st QAD in window       */
/* or on the same day but are different antibiotics from first antibiotic in QAD */
/**NOTE: subsequent QADs can be different antibiotics as long as the first dose of each is “new” (not given in prior 2 days) */


proc sql;
    create table antibiotic_qad_sub1_new as
        select distinct a.Adm_ID,
                        a.PatientID,
                        a.infxn_anchor_day ,
                        a.Day,
                        a.antibiotic,
                        a.antibiotic_new,
                        b.Day_min,
                        b.antibiotic_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_first_new b  /* ANTIBIOTIC_QAD_FIRST_NEW dataset is limited to IV ABX only*/

        where a.Adm_ID = b.Adm_ID 
			and a.PatientID = b.PatientID 
			and a.infxn_anchor_day = b.infxn_anchor_day
            and a.antibiotic ^= 'VANCOMYCIN' 
			and (a.Day > b.Day_min or
               (a.Day = b.Day_min and a.antibiotic ^= b.Antibiotic)
              	);
quit;

proc sort data = antibiotic_qad_sub1_new;
by Adm_ID PatientID infxn_anchor_day  antibiotic Day;
run;

/* Select antibiotics other than VANCOMYCIN when 1st antibiotic is IV & new */
/* or antibiotic is same as IV antibiotic for 1st QAD in window           */

data antibiotic_qad_sub2_new;
    set antibiotic_qad_sub1_new;
        by Adm_ID PatientID  infxn_anchor_day  antibiotic;
        if first.antibiotic and (antibiotic_new = 1 or antibiotic = antibiotic_first);
run;


data antibiotic_qad_sub2_new;
    set antibiotic_qad_sub1_new;
        by Adm_ID PatientID  infxn_anchor_day  antibiotic;
        if first.antibiotic and (antibiotic_new = 1 or antibiotic = antibiotic_first) | antibiotic_new = 1;
run;


%delete_ds(dslist = antibiotic_qad_sub1_new);

/* Select all records for antibiotics other than VANCOMYCIN when 1st IV antibiotic is new */
/* -OR- antibiotic is same as IV antibiotic for 1st QAD in window                           */
/* -OR- **subsequent QADs can be different antibiotics as long as the first does of each is “new” (not given in prior 2 days) */  
proc sql;
    create table antibiotic_qad_sub3_new  as
        select a.*,
               b.Day_min,
               b.Antibiotic_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_sub2_new b
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
			  a.infxn_anchor_day = b.infxn_anchor_day 
              and a.Antibiotic = b.Antibiotic and
              a.Day >= b.Day;
quit;

%delete_ds(dslist = antibiotic_qad_sub2_new);

/* Find VANCOMYCIN antibiotics occuring on or after 1st QAD in window   */
/*   when 1st **IV** antibiotic is not VANCOMYCIN             */
proc sql;
    create table antibiotic_qad_sub1a_van_new as
        select distinct a.Adm_ID,
                        a.PatientID,
                        a.infxn_anchor_day  ,
                        a.Day,
                        a.antibiotic,
                        a.Route,
                        a.antibiotic_new,
                        b.Day_min,
                        b.antibiotic_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_first_new b      
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
			  a.infxn_anchor_day = b.infxn_anchor_day 
              and a.antibiotic = 'VANCOMYCIN' and
              b.antibiotic ^= 'VANCOMYCIN' and
              (a.Day > b.Day_min or
               (a.Day = b.Day_min and a.antibiotic ^= b.Antibiotic)
              );
quit;

proc sort data = antibiotic_qad_sub1a_van_new;
by Adm_ID PatientID infxn_anchor_day  antibiotic route Day;
run;

/* Select VANCOMYCIN when 1st antibiotic is new */
data antibiotic_qad_sub2a_van_new;
    set antibiotic_qad_sub1a_van_new;
    by Adm_ID PatientID infxn_anchor_day antibiotic route;
    if first.route and antibiotic_new = 1;
run;

%delete_ds(dslist = antibiotic_qad_sub1a_van_new);

/* Select all records for VANCOMYCIN when 1st antibiotic is new */
proc sql;
    create table antibiotic_qad_sub3a_van_new as
        select a.*,
               b.Day_min,
               b.Antibiotic_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_sub2a_van_new b
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
		      a.infxn_anchor_day = b.infxn_anchor_day 
              and a.Antibiotic = b.Antibiotic and
              a.Route = b.Route and a.Day >= b.Day;
quit;

%delete_ds(dslist = antibiotic_qaD_sub2a_van_new);

/* Find VANCOMYCIN antibiotics occuring on or after 1st QAD in window when  */
/* 1st antibiotic is VANCOMYCIN                                             */
proc sql;
    create table antibiotic_qad_sub1b_van_new as
        select distinct a.Adm_ID,
                        a.PatientID,
                        a.infxn_anchor_day ,
                        a.Day,
                        a.antibiotic,
                        a.Route,
                        a.antibiotic_new,
                        b.Day_min,
                        b.antibiotic_first,
                        b.route as route_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_first_new b
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
			  a.infxn_anchor_day = b.infxn_anchor_day 
              and a.antibiotic = 'VANCOMYCIN' and
              b.antibiotic = 'VANCOMYCIN' and
              (a.Day > b.Day_min or
               (a.Day = b.Day_min and a.route ^= b.route)
              );
quit;

proc sort data = antibiotic_qad_sub1b_van_new;
by Adm_ID PatientID infxn_anchor_day  antibiotic route Day;
run;


/* Select VANCOMYCIN when 1st antibiotic is new or route is different than 1st route */
data antibiotic_qad_sub2b_van_new;
    set antibiotic_qad_sub1b_van_new;
    by Adm_ID PatientID infxn_anchor_day antibiotic route;
    if first.route and (antibiotic_new = 1 or route = route_first);
run;

%delete_ds(dslist = antibiotic_qaD_sub1b_van_new);

/* Select all records for VANCOMYCIN when 1st antibiotic is new */
proc sql;
    create table antibiotic_qad_sub3b_van_new as
        select a.*,
               b.Day_min,
               b.Antibiotic_first
        from antibiotic_qad_all1 a,
             antibiotic_qad_sub2b_van_new b
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
			  a.infxn_anchor_day = b.infxn_anchor_day 
              and a.Antibiotic = b.Antibiotic and
              a.Route = b.Route and a.Day >= b.Day;
quit;

%delete_ds(dslist = antibiotic_qad_all1 antibiotic_qad_sub2b_van_new);

/* Combine antibiotics for non-Vancomycin and Vancomycin */
data antibiotic_qad_all3_new;
    set antibiotic_qad_first_new 	antibiotic_qad_sub3_new 	antibiotic_qad_sub3a_van_new 	antibiotic_qad_sub3b_van_new;
run;



%delete_ds(dslist = antibiotic_qad_first_new antibiotic_qad_sub3_new antibiotic_qad_sub3a_van_new
                    antibiotic_qad_sub3b_van_new);

proc sort data = antibiotic_qad_all3_new;
by Adm_ID PatientID infxn_anchor_day  Day;
run;

/* Create list of antibiotics for each Admission_ID, patientID, infxn_anchor_day,  Day */
proc transpose data = antibiotic_qad_all3_new
     out = antibiotic_trans_new(drop = _name_) prefix = lag_ab;
     var antibiotic;
     by Adm_ID PatientID infxn_anchor_day Day;
run;

/* Create list of routes for each Admission_ID, patientID, infxn_anchor_day, Day  for VANCOMYCIN  */
proc transpose data = antibiotic_qad_all3_new
     out = antibiotic_trans_route_new(drop = _name_) prefix = van_route;
     var route;
     by Adm_ID PatientId infxn_anchor_day  Day;
     where Antibiotic = "VANCOMYCIN";
run;

/* Find maximum number of antibiotics for an Admission_ID, patientID, infxn_anchor_day, Day */
proc sql noprint;
    select max(N) into :nabnew from
         (select Adm_ID,
                 PatientID,
                 infxn_anchor_day,
                 Day,
                 count(*) as N
          from antibiotic_qad_all3_new
          group by Adm_ID, PatientID, infxn_anchor_day , Day);
quit;

%let nabnew = %trim(&nabnew.);

/* Find maximum number of routes for an Admission_ID, patientID, bcx_drawn_day, Day */
proc sql noprint;
    select max(N) into :nrtnew from
         (select Adm_ID,
                 PatientID,
                  infxn_anchor_day ,
                 Day,
                 count(*) as N
          from antibiotic_qad_all3_new
          where Antibiotic = 'VANCOMYCIN'
          group by Adm_ID, PatientID,  infxn_anchor_day, Day);
quit;

%let nrtnew = %trim(&nrtnew.);

/* Retrieve antibiotics from previous day and previous 2 days */
/* and vancomycin routes from previous 2 days                 */
/* REMEMBER: subsequent QADs can be different antibiotics as long as the first does of each is “new” (not given in prior 2 days) **/



%macro makeab_new;

    proc sql;
        create table tmp.antibiotic_qad_all4_new as
            select a.*,
                 %do i = 1 %to &nabnew.;
                     b.lag_ab&i. as lag1_ab&i.,
                 %end;
                 %do i = 1 %to &nabnew.;
                     c.lag_ab&i. as lag2_ab&i.,
                 %end;

                 %if &nrtnew > 0 %then %do;
                     %do i = 1 %to %eval(&nrtnew- 1);
                         d.van_route&i. as lag2_van_route&i.,
                     %end;
                     d.van_route&nrtnew. as lag2_van_route&nrtnew.

                 %end;
                 %else %do;
                     " " as lag2_van_route1
                 %end;

            from antibiotic_qad_all3_new   a

            left join antibiotic_trans_new b
                on a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.Day = b.Day + 1

            left join antibiotic_trans_new c
                on a.Adm_ID = c.Adm_ID and a.PatientID = c.PatientID and
                   a.infxn_anchor_day = c.infxn_anchor_day  and a.Day = c.Day + 2

            left join antibiotic_trans_route_new d
                on a.Adm_ID = d.Adm_ID and a.PatientID = d.PatientID and
                   a.infxn_anchor_day = d.infxn_anchor_day  and a.Day = d.Day + 2;
    quit;

   %delete_ds(dslist = antibiotic_qad_all3_new);

    /* Determine if antibiotic exists in record 2 days prior to current record */
    data tmp.antibiotic_qad_all5_new;
        set tmp.antibiotic_qad_all4_new;
        array lag2var [&nabnew] lag2_ab1-lag2_ab&nabnew.;
        %if &nrtnew > 0 %then %do;
            array lag2rt [&nrtnew] lag2_van_route1-lag2_van_route&nrtnew.;
        %end;
        find_ab2 = 0;
        do i = 1 to &nabnew.;
            /* For antibiotics other than VANCOMYCIN check if record exists 2 days ago */
            if antibiotic = lag2var[i] then do;
                if antibiotic ^= "VANCOMYCIN" then do;
                    find_ab2 = 1;
                    i = &nabnew.;
                end;
                /* For Vancomycin, check if route matches from 2 days ago */
                else do;
                    %if &nrtnew. > 0 %then %do;
                        do j = 1 to &nrtnew.;
                            if route = lag2rt[j] and lag2rt[j] ^= " " then do;
                                find_ab2 = 1;
                                j = &nrtnew.;
                                i = &nabnew.;
                            end;
                        end;
                    %end;
                end;
            end;
        end;
        no_find_ab2 = 1 - find_ab2;
    run;

    %delete_ds(dslist = antibiotic_qad_all4);

%mend makeab_new;

%makeab_new;


/***********************************************************************/

/* Find all antibiotics in dataset and store in macro variable */
proc sql noprint;
    select distinct antibiotic into :all_antibiotic_new separated by ' '
    from tmp.antibiotic_qad_all5_new;
quit;

/*************************************************************************************/
/* Create rolling sequences of QADs after infxn_anchor_day for each day within     	 */
/* +/- 1 day of blood culture where new antibiotic is received                       */
/* [Change from +/- 2 days  for ASE 1.0]											 */ 
/*************************************************************************************/

proc sql;
    create table bc_qad_start_new as
       select distinct Adm_ID,
                       PatientID,
                       infxn_anchor_day ,
                       day as QAD_start
       from tmp.antibiotic_qad_all5_new
       where -1 <= infxn_anchor_day - day <= 1 and antibiotic_new = 1;
quit;

proc sql;
    create table tmp.antibiotic_qad_all5_roll_new as
        select a.*,
               b.QAD_start
        from tmp.antibiotic_qad_all5_new a,
             bc_qad_start_new b
        where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
              a.infxn_anchor_day = b.infxn_anchor_day  and a.Day >= b.QAD_start;
quit;


/**************************************************************************************/


proc sort data = tmp.antibiotic_qad_all5_roll_new;
by Adm_ID PatientID infxn_anchor_day  QAD_start Day no_find_ab2 Antibiotic;
run;

%global &all_antibiotic_new VANCOMYCIN_IV VANCOMYCIN_PO;



%macro calc_qad;

/* Determine QADs */
/* QAD max is the maximum QAD value in a Admission_ID, patientID, bcx_drawn_day record */

data tmp.antibiotic_qad_all5a_new(drop = i lag: find_ab2 prev_ab2 no_find_ab2 Day_min QAD_max);
    set tmp.antibiotic_qad_all5_roll_new;
    by Adm_ID PatientID  infxn_anchor_day  QAD_start Day no_find_ab2 Antibiotic;
    retain QAD QAD_max prev_ab2;

    if first.Day and find_ab2 = 1 then prev_ab2 = 1;
    else if first.Day then prev_ab2 = 0;

    if first.QAD_start then QAD_max = 1;
    if first.Day and find_ab2 = 0 and
       cmiss(of lag1_ab1-lag1_ab&nabnew.) = &nabnew. then QAD_max = 1;

    /* 1. If record is first for an infxn_anchor_day (bcx_drawn_day) or the Day is the same as the        					*/
    /*    smallest Day, set QAD to 1                                                  										*/
    /* 2. If no antibiotics in previous day or from 2 days ago, reset QAD to 1        										*/
    /* 3. If antibiotic exists in previous day and record is first for a Day          										*/
    /*    increment QAD + 1 from maximum QAD on previous day                          										*/
    /* 4. If antibiotic exists in previous day and record is not first for a Day      										*/
    /*    keep QAD as same value as previous record                                   										*/
    /* 5. If no antibiotics in previous day and antibiotic exists from 2 days ago,    										*/
    /*    check if antibiotic in current record exists from 2 days ago                										*/
    /*    If it does exist, increment QAD by 2, if it does not exist reset QAD to 1   										*/
    /*    For Vancomycin, routes must be same between Day and Day - 2                 										*/
    /*    Macro variable with name of Antibiotic is used to store and process QAD     										*/
    /*    value as dataset is processed. Macro variables VANCOMYCIN_IV, VANCOMYCIN_PO 										*/
    /*    are used to store QAD values for IV, PO routes                              										*/

    /* QAD max is the maximum QAD value in a Admission_ID, patientID, infxn_anchor_day QAD_Start  record 					*/
    /* QAD_max is updated as each record is processed                                                    					*/

    if first.QAD_start or Day = QAD_start then do;
         QAD = 1;
         if Antibiotic ^= "VANCOMYCIN" then call symput(Antibiotic, QAD);
         else if Antibiotic = "VANCOMYCIN" then
            call symput("VANCOMYCIN_" || trim(Route), QAD);
    end;
    else if cmiss(of lag1_ab1-lag1_ab&nabnew.) = &nabnew and
            cmiss(of lag2_ab1-lag2_ab&nabnew.) = &nabnew then do;
        QAD = 1;
        if Antibiotic ^= "VANCOMYCIN" then call symput(Antibiotic, QAD);
        else if Antibiotic = "VANCOMYCIN" then
            call symput("VANCOMYCIN_" || trim(Route), QAD);
    end;
    else if cmiss(of lag1_ab1-lag1_ab&nabnew.) ^= &nabnew. and first.Day
         then do;
              QAD = QAD_max + 1;
              if antibiotic ^= "VANCOMYCIN" then call symput(Antibiotic, QAD);
              else if antibiotic = "VANCOMYCIN" then
                 call symput("VANCOMYCIN_" || trim(route), QAD);
         end;
    else if cmiss(of lag1_ab1-lag1_ab&nabnew.) ^= &nabnew. and first.Day = 0
          then do;
               QAD + 0;
               if Antibiotic ^= "VANCOMYCIN" then call symput(Antibiotic, QAD);
               else if antibiotic = "VANCOMYCIN" then
                   call symput("VANCOMYCIN_" || trim(route), QAD);
          end;
    else if cmiss(of lag1_ab1-lag1_ab&nabnew.) = &nabnew. and
            cmiss(of lag2_ab1-lag2_ab&nabnew.) ^= &nabnew.
            then do;
                 if find_ab2 = 0 and prev_ab2 = 0 then do;
                     QAD = 1;
                     if Antibiotic ^= "VANCOMYCIN" then call symput(Antibiotic, QAD);
                     else if antibiotic = "VANCOMYCIN" then
                        call symput("VANCOMYCIN_" || trim(route), QAD);
                 end;
                 else if prev_ab2 = 1 and Antibiotic ^= "VANCOMYCIN" and first.Day then do;
                     QAD = symget(Antibiotic) + 2;
                     call symput(Antibiotic, QAD);
                 end;
                 else if prev_ab2 = 1 and Antibiotic ^= "VANCOMYCIN" and first.Day = 0 then do;
                     QAD + 0;
                     call symput(Antibiotic, QAD);
                 end;
                 else if prev_ab2 = 1 and Antibiotic = "VANCOMYCIN" and first.Day then do;
                     QAD = symget("VANCOMYCIN_" || trim(Route)) + 2;
                     call symput("VANCOMYCIN_" || trim(Route), QAD);
                 end;
                 else if prev_ab2 = 1 and Antibiotic = "VANCOMYCIN" and first.Day = 0 then do;
                     QAD + 0;
                     call symput("VANCOMYCIN_" || trim(Route), QAD);
                 end;
    end;

    /* Reset macro variables after last record for Admission_ID, patientID, bcx_drawn_day  */

    if last.QAD_start then do;
         %let i = 1;
         %do %while(%length(%scan(&ALL_ANTIBIOTIC_NEW, &i)));
              call symput("%scan(&ALL_ANTIBIOTIC_NEW, &i.)", 1);
              %let i = %eval(&i + 1);
         %end;
         call symput("VANCOMYCIN_IV", 1);
         call symput("VANCOMYCIN_PO", 1);
    end;

    /* Reset QAD_max value */
    QAD_max = max(QAD, QAD_max);

run;

%delete_ds(dslist = antibiotic_qad_all5);

%mend calc_qad;

%calc_qad;

/******************************************************************************************************************************/
/*  ASE 2.0 Update for the Shortened Infection window (occurs +/- 1 day, instead of 2 days)				  				  */
/******************************************************************************************************************************/

/* Remove cases where 1st QAD is outside of +/- days from blood culture date */

data tmp.antibiotic_qad_all5b_NEW;
    set tmp.antibiotic_qad_all5a_new;
    if ~(infxn_anchor_day -1  <= Day - QAD + 1 <= infxn_anchor_day+1 )
         then QAD = 0;
    if QAD ^= 0;
run;



/* Remove cases when QAD was reset to 1 in a later day */
proc sql;
    create table tmp.QAD_max_seq_new as
        select Adm_ID,
               PatientID,
               infxn_anchor_day ,
               QAD_start,
               max(QAD) as QAD_max,
               max(Day) as Day_max
        from tmp.antibiotic_qad_all5b_NEW 
        group by Adm_ID, PatientID, infxn_anchor_day , QAD_start;
quit;

proc sql;
    create table tmp.antibiotic_qad_all5c_new as
    select a.* 
    from tmp.antibiotic_qad_all5b_NEW a,
         tmp.QAD_max_seq_new b
    where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
          a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start and
          a.QAD - a.Day = b.QAD_max - b.Day_max;
quit;

%delete_ds2(dslist2 = antibiotic_qad_all5a);



/*******************************************************/
/*** VII.  Infection based on QAD4   				****/
/*******************************************************/


/* Select only cases with at least 1 QAD with IV route in days 1-4 */
/* At least one of the first 4 QAD's must include an IV antibiotic **/

proc sql;
    create table tmp.qad_iv_min_new as
        select Adm_ID,
               PatientID,
               infxn_anchor_day ,
               QAD_start,
               min(QAD) as QAD_IV_min
        from tmp.antibiotic_qad_all5c_new
        where Route = 'IV'
        group by Adm_ID, PatientID, infxn_anchor_day, QAD_start;
quit;

	proc sql;
	    create table tmp.ab_qad_all6_ehr_new as
	             select a.*
	                 from tmp.antibiotic_qad_all5c_new a,
	                      tmp.qad_iv_min_new b
	         where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
	               a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start and
	               1 <= b.QAD_IV_min <= 4;
	quit;



/* Retrieve hospital_id, encounter_type, discharge_date, discharge_dispo, */
/* from basic dataset                                                     */
proc sql;
    create table tmp.antibiotic_qad_hosp1_new as
        select a.*,
               b.Hospital_ID,
               b.Encounter_type,
               b.Discharge_date,
			   b.discharge_day,
               b.Discharge_dispo
        from tmp.ab_qad_all6_ehr_new a
        left join basic_fnl b
           ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID;
quit;



/* Separate antibiotic results by encounter type */
data tmp.antibiotic_qad_ip1_new tmp.antibiotic_qad_ed1_new;
    set tmp.antibiotic_qad_hosp1_new;
    if day > discharge_day  then delete;
    if encounter_type = 'I' then output tmp.antibiotic_qad_ip1_new;
    else if encounter_type = 'E' then output tmp.antibiotic_qad_ed1_new;
run;


%macro qad_gelt4(type);

    /* Create datasets for encounters with at least 1 QAD >= 4 days        */
    /* and for those with no QAD >= 4 days, for a specified encounter type */

    /* Select encounters with QAD >= 4 days */
    proc sql;
        create table tmp.antibiotic_qad_&type.1_ge4_new as
            select a.*
            from tmp.antibiotic_qad_&type.1_new a,
            (select distinct Adm_ID,
                             PatientID,
                             infxn_anchor_day ,
                             QAD_start
             from tmp.antibiotic_qad_&type.1_new
             where QAD >= 4
             ) b
             where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

    /* Select ED encounters with max QAD < 4 days */
    proc sql;
        create table tmp.antibiotic_qad_&type.1_lt4_new as
            select a.*
                from tmp.antibiotic_qad_&type.1_new a,
                (select distinct Adm_ID,
                                 PatientID,
                                 infxn_anchor_day ,
                                 QAD_start,
                                 max(QAD) as qad_max
                 from tmp.antibiotic_qad_&type.1_new
                 group by Adm_ID, PatientID, infxn_anchor_day , QAD_start
                 having qad_max < 4
                 ) b
            where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                  a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

%mend qad_gelt4;



%qad_gelt4(type = IP);
%qad_gelt4(type = ED);

%macro qadenc_ge4(type);

    /* Select all data for a Admission_ID, patientID, bcx_drawn_day  */
    /* where at least 1 QAD >= 4 and determine 1st QAD                */

    /* Select encounters with QAD >= 4 days */
    /* replace antibiotic_qad_IP1 with antibiotic_qad_&type.1 */ 
    proc sql;
        create table tmp.antibiotic_qad_&type.1_ge4_new as
            select a.*
            from tmp.antibiotic_qad_&type.1_new a,
            (select distinct Adm_ID,
                             PatientID,
                             infxn_anchor_day ,
                             QAD_start
             from tmp.antibiotic_qad_&type.1_new
             where QAD >= 4
             ) b
             where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day  and a.QAD_start = b.QAD_start;
    quit;

    /* Find first QAD for sequence of antibiotics with QAD >= 4 */
    proc sql;
        create table tmp.antibiotic_qad_&type.2_ge4_new as
            select Adm_ID,
                   PatientID,
                   infxn_anchor_day ,
                   QAD_start,
                   min(Day - QAD + 1) as QAD_first
            from tmp.antibiotic_qad_&type.1_ge4_new
            where QAD >= 4
            group by Adm_ID, PatientID, infxn_anchor_day , QAD_start;
    quit;

    /* Retrieve information for 1st QAD and combine with antibiotic, QAD data */
    proc sql;
        create table tmp.antibiotic_qad_&type.3_ge4_new as
            select a.*,
                   b.QAD_first
            from tmp.antibiotic_qad_&type.1_ge4_new a
            LEFT JOIN tmp.antibiotic_qad_&type.2_ge4_new b
                ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

    proc sort data = tmp.antibiotic_qad_&type.3_ge4_new;
    by Adm_ID PatientID infxn_anchor_day  QAD_start Day Antibiotic route;
    run;

%mend qadenc_ge4;

%qadenc_ge4(type = IP);
%qadenc_ge4(type = ED);


*%delete_ds2(dslist2 = antibiotic_qad_IP1 antibiotic_qad_ED1);

/* If patient has < 4 QADs, patient qualifies if: (1) death, (2) discharge to another hospital, (3) hospice [NEW], or (4) comfort care  */
/* or outpatients occurs before 4 QADs have elapsed, then patient can qualify for                                                       */
/* suspected infection with < 4 QADs so long as they have consecutive QADs until day                                                    */
/* of, or 1 day prior to, death or discharge,  or comfort_care                                                                          */
				
		/******************************************
		VALUES for DISCHARGE_DISPO:
		1 - Home
		2 - Transfer to another acute care hospital
		3 - Subacute facility
		4 - Death
		5 - Hospice
		*******************************************/


/*******************************************************************************************************/
/** INCORPORATE COMFORT CARE DATASET  ******/
data comfortcare;
set raw.comfortcare;
run;

/* Update macro [%QADENC_LT4_CC] for transition to Comfort Care Order */
%macro qadenc_lt4_ccnew(type, dischval);

    /* Select all data for an Admission_ID, patientID, bcx_drawn_day   */
    /* where patient dies (or dc to hospice/acute care or comfort care) and Day within 1 day of discharge date        */
	/* NOTE: Comfort Care Order may occur before discharge [NEW 12/17/24]****/

    /* Select all data for an Admission_ID, patientID, bcx_drawn_day   */
    /* where patient dies and Day within 1 day of discharge date        */
	/*MACRO VBLS &type. */

			proc sql;
			create table tmp.antibiotic_qad_&type.1_lt4_cc_new as
			select a.*, b.admission_date, b.discharge_day
			from tmp.antibiotic_qad_&type.1_lt4_new as a LEFT JOIN basic_fnl as b
			on a.adm_id=b.adm_id;
			quit;


			*Merge comfort care dataset to antibiotic_qad lt4;
		    proc sql;
		    create table tmp.antibiotic_qad_&type.1a_lt4_cc_new as

				select 	a.*, 
					b.comfortcare_day as day_comfortcare, 
					b.comfort_care_enc as comfortcare

				from  tmp.antibiotic_qad_&type.1_lt4_cc_new  as a LEFT JOIN  comfortcare as b
		             on a.Adm_ID = b.Adm_Id and a.PatientId = b.PatientID;
		    quit;



			*Merge DATE_OF_DEATH variable to antibiotic_qad lt4 (from basic_fnl);
		    proc sql;
		    create table tmp.antibiotic_qad_&type.1b_lt4_cc_new as

				select 	a.*, 
					b.deathDTS_derived, 
					b.date_of_death, 
					(b.date_of_death-a.admission_date)+1 as death_day_derived


				from  tmp.antibiotic_qad_&type.1a_lt4_cc_new   as a LEFT JOIN  basic_fnl as b
		             on a.Adm_ID = b.Adm_Id and a.PatientId = b.PatientID;
		    quit;


			/*Include records where abx are given within 1 day of Comfort care order: (Day - day_comfortcare) in (-1,0,1))  */
			/*-OR-  within 1 day of DATE_OF_DEATH : (Day - DATE_OF_DEATH) in (-1,0,1))  - NOTE: DISCHARGE_DISPO & DATE_OF_DEATH may not be consistent*/

		    proc sql;
		        create table tmp.qad_&type.1_lt4_dis_cc_new as
		            select a.*
		                from tmp.antibiotic_qad_&type.1b_lt4_cc_new  a,
		                (select distinct Adm_ID,
		                                 PatientID,
		                                 infxn_anchor_day ,
		                                 QAD_start, day, discharge_day
		                 from tmp.antibiotic_qad_&type.1b_lt4_cc_new

	                      where (
								(comfortcare=1 and (Day-day_comfortcare) in (-1,0,1)) or (Discharge_dispo IN(2,4,5) and (Day-Discharge_day) in (-1,0,1))
								or ((Day-death_day_derived) in (-1,0,1))
		                 		)) b

		                 where a.Adm_ID = b.Adm_Id and a.PatientId = b.PatientID and
		                       a.infxn_anchor_day = b.infxn_anchor_day  and a.QAD_start = b.QAD_start;
		    quit;

		    /* Find first QAD for sequence of antibiotics with death and Day    */
		    /* within 1 day of discharge date                */
			/* -OR- Day within 1 day of comfort care date    */
			/* -OR- Day within 1 day of death_day_derived    */

		    proc sql;
		        create table tmp.qad_&type.2_lt4_dis_cc_new as
		            select Adm_ID,
		                   PatientID,
		                   infxn_anchor_day ,
		                   QAD_start,
		                   min(Day - QAD + 1) as QAD_first
		            from  tmp.qad_&type.1_lt4_dis_cc_new
				    where (Day >= Discharge_day - 1) or (Day >= day_comfortcare - 1) or  (Day >= death_day_derived - 1)  
		            group by Adm_ID, PatientID,  infxn_anchor_day , QAD_start;
		    quit;

		    /* Retrieve information for 1st QAD and combine with antibiotic, QAD data */
		    proc sql;
		        create table tmp.qad_&type.3_lt4_dis_cc_new as
		            select a.*,
		                   b.QAD_first
		            from tmp.qad_&type.1_lt4_dis_cc_new a
		            LEFT JOIN tmp.qad_&type.2_lt4_dis_cc_new  b
		                ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
		                    a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
		    quit;


%mend qadenc_lt4_ccnew;



/*****/

%qadenc_lt4_ccnew(type = IP, dischval = %str(2, 4, 5));
%qadenc_lt4_ccnew(type = ED, dischval = %str(2, 4, 5)); 

/**** END - Infection based on QAD4 and <4 QAD's ****/



/*******************************************************/
/*** VII.  Infection based on 3QADs & DC alive  	****/
/*******************************************************/

/* Select only cases with at least 1 QAD with IV route in days 1-3 */
/* "At least one of the first 3 QAD's must include an IV antibiotic" **/
proc sql;
    create table tmp.qad3_iv_min_new as
        select Adm_ID,
               PatientID,
               infxn_anchor_day ,
               QAD_start,
               min(QAD) as QAD_IV_min
        from tmp.antibiotic_qad_all5c_new
        where Route = 'IV'
        group by Adm_ID, PatientID, infxn_anchor_day , QAD_start;
quit;

	proc sql;
	    create table tmp.ab_qad3_all6_ehr_new as
	             select a.*
	                 from tmp.antibiotic_qad_all5c_new  a,
	                      tmp.qad3_iv_min_new  b
	         where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
	               a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start and
	               1 <= b.QAD_IV_min <= 3;
	quit;

/* Retrieve hospital_id, encounter_type, discharge_date, discharge_dispo, */
/* from basic dataset                                                     */
proc sql;
    create table tmp.antibiotic_qad3_hosp1_new  as
        select a.*,
               b.Hospital_ID,
               b.Encounter_type,
               b.Discharge_date,
			   b.discharge_day,
               b.Discharge_dispo
        from tmp.ab_qad3_all6_ehr_new  a
        left join basic_fnl b
           ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID;
quit;


/* Separate antibiotic results by encounter type */
data tmp.antibiotic_qad3_ip1_new  tmp.antibiotic_qad3_ed1_new ;
    set tmp.antibiotic_qad3_hosp1_new ;
    if day > discharge_day then delete;
    if encounter_type = 'I' then output tmp.antibiotic_qad3_ip1_new;
    else if encounter_type = 'E' then output tmp.antibiotic_qad3_ed1_new;
run;






/***********************************************************************************/
%macro qad_gelt3(type);

    /* Create datasets for encounters with at least 1 QAD >= 3 days        */
    /* and for those with no QAD >= 3 days, for a specified encounter type */

    /* Select encounters with QAD >= 3 days */
    proc sql;
        create table tmp.antibiotic_qad3_&type.1_ge3_new as
            select a.*
            from tmp.antibiotic_qad3_&type.1_new a,
            (select distinct Adm_ID,
                             PatientID,
                             infxn_anchor_day,
                             QAD_start
             from tmp.antibiotic_qad3_&type.1_new
             where QAD >= 3
             ) b
             where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

    /* Select ED encounters with max QAD < 3 days */
    proc sql;
        create table tmp.antibiotic_qad3_&type.1_lt3_new as
            select a.*
                from tmp.antibiotic_qad3_&type.1_new a,
                (select distinct Adm_ID,
                                 PatientID,
                                 infxn_anchor_day,
                                 QAD_start,
                                 max(QAD) as qad_max
                 from tmp.antibiotic_qad3_&type.1_new
                 group by Adm_ID, PatientID, infxn_anchor_day, QAD_start
                 having qad_max < 3
                 ) b
            where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                  a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

%mend qad_gelt3;

%qad_gelt3(type = IP);
%qad_gelt3(type = ED);



%macro qadenc_ge3(type);

    /* Select all data for a Admission_ID, patientID, bcx_drawn_day  */
    /* where at least 1 QAD >= 3 and determine 1st QAD                */

    /* Select encounters with QAD >= 3 days */
    proc sql;
        create table tmp.antibiotic_qad3_&type.1_ge3_new as
            select a.*
            from tmp.antibiotic_qad3_&type.1_new a,
            (select distinct Adm_ID,
                             PatientID,
                             infxn_anchor_day,
                             QAD_start
             from tmp.antibiotic_qad3_&type.1_new
             where QAD >= 3
             ) b
             where a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

    /* Find first QAD for sequence of antibiotics with QAD >= 3 */
    proc sql;
        create table tmp.antibiotic_qad3_&type.2_ge3_new as
            select Adm_ID,
                   PatientID,
                   infxn_anchor_day,
                   QAD_start,
                   min(Day - QAD + 1) as QAD_first
            from tmp.antibiotic_qad3_&type.1_ge3_new
            where QAD >= 3
            group by Adm_ID, PatientID, infxn_anchor_day, QAD_start;
    quit;

    /* Retrieve information for 1st QAD and combine with antibiotic, QAD data */
    proc sql;
        create table tmp.antibiotic_qad3_&type.3_ge3_new as
            select a.*,
                   b.QAD_first
            from tmp.antibiotic_qad3_&type.1_ge3_new a
            LEFT JOIN tmp.antibiotic_qad3_&type.2_ge3_new b
                ON a.Adm_ID = b.Adm_ID and a.PatientID = b.PatientID and
                   a.infxn_anchor_day = b.infxn_anchor_day and a.QAD_start = b.QAD_start;
    quit;

    proc sort data = tmp.antibiotic_qad3_&type.3_ge3_new;
    by Adm_ID PatientID infxn_anchor_day QAD_start Day Antibiotic route;
    run;

%mend qadenc_ge3;

%qadenc_ge3(type = IP);
%qadenc_ge3(type = ED);

/*%delete_ds2(dslist = tmp.antibiotic_qad_IP1 tmp.antibiotic_qad_ED1);*/


/** CRITERIA FOR PRESUMED QAD3 INFECTION:   **/
	* Limit to Encounters that are (discharged (1) ALIVE and (2)discharged on QAD3;

	* COMBINE QAD3 INFECTION DATASETS (for QAD3 only, as additional processing still necessary);
	* SKIP Macro for Comfort Care and QAD3 (not relevant for this subset);

	data qad3_infection_all1_new;
	    set tmp.antibiotic_qad3_ip3_ge3_new 
	        tmp.antibiotic_qad3_ed3_ge3_new ;
	run;


	*CREATE working subset:  EXCLUDE all infection cases that are discharged to death, hospice, or acute care facility;
	***  Want to keep patients discharged ALIVE to home (1) or subacute facility (3) ;

			proc sql;
			create table qad3_infection_all2_new as 
			select adm_id, patientID,  encounter_type,
				   discharge_date, 	discharge_day, discharge_dispo,
				   infxn_anchor_day, 
				   antibiotic, antibiotic_new, route,day,
				   qad, QAD_first, qad_start
			from qad3_infection_all1_new
			where 	discharge_dispo in (1,3) ;
			quit;


	* Identify cases discharged on QAD3;
	** Identify the first-occuring QAD in this antibiotic series;
	proc sql;
	create table qad3_infection_all3_new as
	select * , min(QAD_first) as QAD_first_enc
	from qad3_infection_all2_new
	group by adm_id
	order by adm_id;
	quit;

		*Limit to first-occuring QAD series [recall:  this subset already limited to those ith at least 3 QAD's];
		data qad3_infection_all4_new;
		set qad3_infection_all3_new;
		where QAD_first_enc=QAD_first;
		run;

			*Take max QAD;
			proc sql;
			create table qad3_infection_all5_new as
			select *,
				max(qad) as qad_max_enc
			from qad3_infection_all4_new
			group by adm_id
			order by adm_id;
			quit;

			*Limit to records where maxQAD=3 ;
			data qad3_infection_all6_new;
			set qad3_infection_all5_new;
			if day=discharge_day then flag_dc_day3=1; 
			where qad_max_enc=3;
			run;

					*Select encounters where patient was DISCHARGED ALIVE on QAD3;
					proc sql;
					create table qad3_infection_all7_new as
					select *, max(flag_dc_day3) as flag_dc_day3_enc
					from qad3_infection_all6_new
					group by adm_id
					order by adm_id;
					quit;


						data qad3_infection_all8_new;
						set qad3_infection_all7_new;
						where flag_dc_day3_enc=1;
						run;


						*Select distinct;
						proc sql;
						create table qad3_infection_all9_new as
						select distinct adm_id, patientID, encounter_type,
								discharge_date,
								discharge_day,
								discharge_dispo,
								qad_first,
								qad_first_enc,
								qad_max_enc,   
								infxn_anchor_day, 
								antibiotic,
								antibiotic_new,
								route,	
								day,
								qad,
								qad_start,
								max(flag_dc_day3) as qad3_keep label='FLAG=disharged alive on QAD3'
						from qad3_infection_all8_new
						group by adm_id
						order by adm_id;
						quit;


							/*	*Collapse to encounter level/Select distinct */
								*limit to vbls of interest;
								proc sql;
								create table qad3_infection_final as
								select distinct adm_id, 
										patientID, 
										1 as infection,
										1 as inf_qad3,
										qad3_keep as qad3_keep_enc label='FLAG: discharged alive on QAD3 (enc-level)',
										infxn_anchor_day,
										qad_first,
										qad_max_enc

									from qad3_infection_all9_new
								group by adm_id
								order by adm_id;
								quit;

				*Final QAD3_DCalive dataset;
				data ehr_infection_qad3_new;
				set qad3_infection_final;
				where qad3_keep_enc=1;
				run;

					proc sort;
					 by Adm_ID PatientID infxn_anchor_day;
					run;

/****************** END  3QADs & DC alive  	*********************************************************************************/


/*** VIII.  Create final INFECTION dataset (combine QAD3 & QAD4 datasets)*	****/
		  * Final dataset includes QAD4 & QAD3(discharged alive only);

	/*(A) Refine QAD4 dataset:  combine QAD4 subsets**/

		data QAD4_all;
		set tmp.antibiotic_qad_ip3_ge4_new    tmp.qad_ip3_lt4_dis_cc_new
		    tmp.antibiotic_qad_ed3_ge4_new 	  tmp.qad_ed3_lt4_dis_cc_new;
		run;

			*Add indicator vbl for type of Infection (QAD,  QAD4);
			proc sql;
			    create table ehr_infection_qad4_new as
			        select  distinct Adm_ID,
			                PatientID,
			                1 as infection,
							1 as inf_qad4,
			            	infxn_anchor_day,
			                min(QAD_first) as QAD_first
			        from  QAD4_all 
			        group by Adm_ID, PatientID, infxn_anchor_day
					order by  Adm_ID, PatientID, infxn_anchor_day;  
			quit; 



	/*(B)  COMBINE QAD3 & QAD4 datasets (final versions) */

		data ehr_infection_all;
		set ehr_infection_qad4_new 	 ehr_infection_qad3_new ;
		run;


		*Limit to vbls of interest/ select distinct;
		proc sql;
		create table ehr_infection_all2 as
		select distinct adm_id, 
			patientID,
			infxn_anchor_day,
			QAD_first,
			infection,
			inf_qad4, 
			inf_qad3, qad3_keep_enc

		from ehr_infection_all
		group by adm_id 
		order by adm_id;
		quit;





/** ADD indicator vbl for: BLOOD_CULTURE, DXPOA_INF_PRIMARY, DISCHARGE DISPOSITION, DATE OF DEATH */
		proc sql;
		create table ehr_infection_all4 as
		select a.adm_id,
				a.patientID,
				b.admission_date,
				b.discharge_date,
				b.discharge_day,
				a.infection,
				a.inf_qad4,
				a.inf_qad3,
				a.qad3_keep_enc,
				b.dxpoa_inf_primary,
				b.blood_culture,
				b.bcx_drawn_day,
				a.infxn_anchor_day,
				a.qad_first, 
				c.discharge_dispo,
				c.dd_group,
				c.date_of_death

	from ehr_infection_all2 as a LEFT JOIN bloodculture_dxpoa_fnl as b
		on a.adm_id=b.adm_id and a.infxn_anchor_day=b.infxn_anchor_day

	LEFT JOIN basic_fnl as c 
		on a.adm_id=c.adm_id;
	quit;


/*RECODE THAT NULLIFIES QAD3 CASES FROM PRESUMED SERIOUS INFECTION :
		Filter out infection cases that are  discharged alive on QAD3 for Comm-Infection/Sepsis (must also include bcx & dxpoa_inf_primary) 
		-0R- who had <4QADS, but last QAD is within 1 day of death/hospice/comfort care 
		 ==>  Will need to exclude such cases from infection (where INFECTION_EXCEPT = 1) ***/

	/*Create indicator variable for INFECTION_EXCEPT */
		data  ehr_infection_all5;	
	    set ehr_infection_all4 ;

			if ( (infection = 1 and inf_qad4=1) and infxn_anchor_day  >= 4 and QAD_first >= 4  )    /* Hosp infection (must have 4 QAD's)*/
			OR   (infection = 1 and inf_qad4=1) 													/* Comm infection (can include 4QAD's or discharged alive on QAD3) **/
			OR (
				 (inf_qad3=1 and qad3_keep_enc=1 and blood_culture=1 and dxpoa_inf_primary=1)  and infxn_anchor_day < 4  )

				then infection_except = 1;
			    else infection_except = 0;

		rename infection = infection_prelim;
		run;


	/*Create final INFECTION variable  & rename INFECTION vbl to avoid confusion down the line **/
		data ehr_infection_all6;
		set ehr_infection_all5;
		infection = min(infection_prelim, infection_except);
		run;

/*Add recode for Infection onset day:    INFXN_ONSET_DAY = min(inxn_anchor_day, qad_first) */

data ehr_infection_all7 ;
set ehr_infection_all6 ;
	infxn_onset_day	= min(infxn_anchor_day, qad_first) ;
	infxn_anchorDT	=(admission_date + infxn_anchor_day)-1;
	infxn_onsetDT	=(admission_date + infxn_onset_day)-1;

format infxn_onsetDT infxn_anchorDT mmddyy10.;
run;


		*SELECT DISTINCT/ RE-ARRANGE;
		proc sql;
		create table ehr_infection_all8 as
		select distinct 	adm_id,
							patientID,
							admission_date,
							discharge_date,
							discharge_day,
							infection_prelim,
							inf_qad4,
							inf_qad3,
							qad3_keep_enc,
							dxpoa_inf_primary,
							blood_culture,
							bcx_drawn_day,
							infxn_anchor_day,
							infxn_anchorDT,
							QAD_first,
							infxn_onset_day,
							infxn_onsetDT,
							discharge_dispo,
							dd_group,
							date_of_death,
							infection_except,
							infection

		from ehr_infection_all7;
		quit;

	*SAVE ehr_infection_all4 for future reference (includes ALL records where infection in (0,1) -- if need to examine QAD3 infection cases);
	data tmp.ehr_infection_all8;
	set ehr_infection_all8;
	run;


/***************************************************************************************/
 *SAVE TO PERM DATASET:  Limit to Infection cases only;
	data  final.ehr_infection;
	set ehr_infection_all8;
	where infection=1;
	run ;
/***************************************************************************************/


/*****************************************************************************************************************************************/
/*****************************************************************************************************************************************/
/*****************************************************************************************************************************************/

*Final QC;
data test;
set final.ehr_infection;
year=year(admission_date);
run;


		title 'FINAL QC';
		*Overall;
		proc freq;
		tables infection inf_qad4 inf_qad3 blood_culture dxpoa_inf_primary/missing;
		run;

		*by year;
		proc freq;
		tables (infection inf_qad4 inf_qad3 blood_culture dxpoa_inf_primary)*year/missing;
		run;

		*stratified ;
		proc freq;
		tables infection*(inf_qad4 inf_qad3) blood_culture*dxpoa_inf_primary/missing;
		run;
