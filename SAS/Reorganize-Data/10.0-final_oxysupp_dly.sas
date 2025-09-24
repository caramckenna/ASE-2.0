*********************************************************************************
* PROGRAM: 10.0-final_oxysupp_dly   

* Author:   Christina Chan                                                            
*                                                                               
* PURPOSE: Create standardized input dataset on oxygen device data used throughout hospital stay
 
* DATE 		9/7/22:   Use updated mappings [NEW VBLS:	o2DeviceMappedNew2 & o2DeviceMappedNew2N]
*  				7/10/24:   Update Oxy Device Mappings for BIPAP 
*  				1/16/25 - Update OXYSUPP device Mappings (use v3 mappings)
*  				5/20/25 - Update Oxy Device mappings:  Use oxygen device mapping scheme from Sepsis TIme Zero project,  where *vent mode* records 
				    				are merged to "O2 Device" records with the exact same patientID & date time.  
				    				The value from *vent mode* record is only used when there is not a corresponding *O2 device* record
*  				9/02/25 - Change structure of dataset:  Now pulling in ALL devices (not just worst_daily)

***************************************************************************

Datasets:    

			INPUT:		raw.basic
								edw.Oxysupp_allmgb_2021_2023 
						   ==> Oxygen delivery device data (all devices from flowsheet, not just first/last):



			OUTPUT:  	raw.oxy_supp



********************************************************************************************************;

proc options group=memory; run;
proc options option=(work utilloc) value; run;
proc options option=threads; run;
options fullstimer msglevel=i ;

*Filepath for population datasets (population datasets - daily & encounter-level);
libname edw 'xx ';
libname derived 'yyy';


*libname for FINAL;
libname tmp 'Z:\Reorganize Data v6.3\Tmp';
libname raw 'Z:\Reorganize Data v6.3\Output';




*(1) pull in Data from Basic (encounter-level)  ;
* Limit to variables of interest from BASIC;

			proc sql;
			create table basic_abbrev as
			select adm_id, 
					patientId,
					admission_date, 
					admit_date_hosp,
					discharge_date,
					hospital_id,
					year
					from raw.basic; 
			quit;


/*************************************************************************************************/

*(2) Pull in O2 DEVICES DATASET;

*(3) Merge BASIC To OXYSUPP (need admission_date BASIC);

		data oxysupp;
		set edw.Oxysupp_allmgb_2021_2023 ;
		 run;

			 *Limit to variables of interest;
			 proc sql;
			 create table oxysupp2 as
			 select distinct  adm_id, 
					recordedDTS ,
					recordedDT ,
					timepart(recordedDTS) as recordedTM format time.w.d. label='recorded time',
					flowsheetMeasureNM,
					displayNM,
					measureTXT,
					o2Device,
					o2DeviceMappedv2 ,
					o2DeviceMappedv2N
			from oxysupp;
			quit;


				proc sql;
				create table basic_oxy as
				select a.*, b.*
				from basic_abbrev as a LEFT JOIN oxysupp2 as b
				on a.adm_id=b.adm_id;
				quit;



					*(3A) Add recode for oxy_day;
					proc sql;
					create table basic_oxy2 as
					select  distinct adm_id,  
							patientID ,
							admission_date, discharge_date, hospital_id,
							recordedDTS,
							recordedDT, 
							recordedTM,
							flowsheetMeasureNM,
							displayNM,
							measureTXT,
							(recordedDT-admission_date)+1 as oxy_day,
							o2Device,
							o2DeviceMappedv2 ,
							o2DeviceMappedv2N
					from basic_oxy;
					quit;


*(3B) UPDATED OXYSUPP MAPPINGS 1/21/25 (Add 'NIV - CPAP', 'NIV - PS', 'NIV - ST');

data basic_oxy4 ;
length o2DeviceMappedv3 $13.;
set basic_oxy2 ;
  if flowsheetMeasureNM='R IP VENT MODE' and displayNM='Vent Mode' 
	 and measureTXT in ('BiPAP', 'CPAP', 'NIV','NIV - CPAP', 'NIV - PS', 'NIV - ST') then do;
		o2DeviceMappedv3='BIPAP';
		o2DeviceMappedv3N=6;
  end;
	else do;
		o2DeviceMappedv3=o2DeviceMappedv2;
		o2DeviceMappedv3N= o2DeviceMappedv2N;
	end;

	if recordedDT = . then delete;
run;

	*==>>> *NOTE: # we don't need pump flow rows - they all have a corresponding device or vent mode record;


* Updated 5/20/25 - Update for ASE 2.0
			1. Use new Oxy Device mappings:  
			Use sepsis time zero oxygen device mapping scheme where:
			 *vent mode* records are merged to "O2 Device" records with the exact same patientID & date time.  
			The value from *vent mode* record is only used when there is not a corresponding *O2 device* record


			/**(1_stz) Create O2_DEVICE dataset **/
				proc sql;
				create table  o2_device as
				select distinct adm_id, patientID, recordedDTS, displayNM ,measureTXT,o2DeviceMappedv3
				from basic_oxy4
				where (displayNM="O2 Device"| displayNM="O2 Delivery" );
				quit;

			/*(2_stz)  Create O2_VENTMODE dataset*/
				proc sql;
				create table  o2_ventMode as
				select distinct adm_id, patientID, recordedDTS, 
						displayNM ,
						measureTXT ,
						o2DeviceMappedv3 
				from basic_oxy4
				where (displayNM="Vent Mode");
				quit;

			*(3_stz) Merge o2_device & ventMode;
			 
				proc sql;
				create table o2DevSTZ as 
				select  a.adm_id as adm_id_dev,
						a.recordedDTS as recordedDTS_dev,
						a.patientID,
						a.displayNM 		as displayNM_dev,
						a.measureTXT 		as measureTXT_dev,
						a.o2DeviceMappedv3 	as o2DeviceMappedv3_dev,

						b.adm_id as adm_id_vm,
						b.recordedDTS as recordedDTS_vm,
						b.displayNM 		as displayNM_vm,
						b.measureTXT 		as measureTXT_vm,
						b.o2DeviceMappedv3 	as o2DeviceMappedv3_vm 

				from o2_device	as a FULL OUTER JOIN o2_ventMode as b
				on a.adm_id=b.adm_id and a.recordedDTS = b.recordedDTS ;
				quit;


				*Create common adm_id & recordedDTS;
				proc sql;
				create table o2DevSTZ1 as 
				select max(adm_id_dev, adm_id_vm) as adm_id,
				max(recordedDTS_dev, recordedDTS_vm) as recordedDTS format B8601DZ35., 
				*
				from o2DevSTZ;
				quit;


			*(4_stz) Add recode for STZ mappings;
				data o2DevSTZ2;
				set o2DevSTZ1;
				if o2DeviceMappedv3_dev= ' ' 
				then 	o2DeviceMappedSTZ = o2DeviceMappedv3_vm;
				else 	o2DeviceMappedSTZ = o2DeviceMappedv3_dev;

				*Rcode into numeric:   o2DeviceMappedSTZn;
				if o2DeviceMappedSTZ="NONE" 			then o2DeviceMappedSTZn= 0;
				if o2DeviceMappedSTZ="NASAL CANNULA" 	then o2DeviceMappedSTZn= 1;
				if o2DeviceMappedSTZ="SIMPLE MASK" 		then o2DeviceMappedSTZn= 2;
				if o2DeviceMappedSTZ="OXYMIZER" 		then o2DeviceMappedSTZn= 3;
				if o2DeviceMappedSTZ="ADVANCED MASK" 	then o2DeviceMappedSTZn= 4;
				if o2DeviceMappedSTZ="HIGH FLOW" 		then o2DeviceMappedSTZn= 5;
				if o2DeviceMappedSTZ="BIPAP" 			then o2DeviceMappedSTZn= 6;
				if o2DeviceMappedSTZ="VENTILATOR" 		then o2DeviceMappedSTZn= 7;
				if o2DeviceMappedSTZ="ECMO" 			then o2DeviceMappedSTZn= 8;

				run;

			*(5_stz) Extract date from recordedDTS;
				data o2DevSTZ3;
				set o2DevSTZ2;
				recordedDT=datepart(recordedDTS);
				format recordedDT mmddyy10.;
				run;

*(6_stz) Merge back to BASIC to add admission date;
proc sql;
create table  o2DevSTZ4 as
select distinct a.adm_id, a.patientID, a.admission_date, a.admit_date_hosp, a.discharge_date, b.*
from basic_abbrev as a INNER JOIN o2DevSTZ3 as b
on a.adm_id=b.adm_id;
quit;


/********************************************



*RESUME, using updated mappings from STZ:   o2DeviceMappedSTZ  o2DeviceMappedSTZn;

 /** (4) Next, re-set values for 1 = None (aka, room air) to missing -so can ID hospital days with missing data on O2 device;*/
	  /*NOTE:  Treat NONE as missing (or room air) */
       data basic_oxy6;
       set o2DevSTZ4;
	   if o2DeviceMappedSTZn =0  then o2DeviceMappedSTZn=.;
       run;



/** (5) ID/Create vbl for hospital day where O2 device is not missing;*/
              data basic_oxy9;
              set basic_oxy6 ;

              if recordedDT ne . then do;
                    oxysupp_hospdate=recordedDT;
                    oxysupp_hospday= (recordedDT-admission_date)+1;
					oxysupp_hospday_orig= (recordedDT-admit_date_hosp)+1; 
              end;

			  label oxysupp_hospdate="hospital day for oxy device";
              label oxysupp_hospday="hospital date for oxy device";
			  label oxysupp_hospday_orig="Oxy Device day, relative to admit_date_hosp (for ASE 1.0)";

              format oxysupp_hospdate mmddyy10.;

			 run;

	*(6)Add other pt_identifiers;
	proc sql;
	create table basic_oxy10
	as select a.*, b.*
	from basic_abbrev as a RIGHT JOIN basic_oxy9 as b
	on a.adm_id=b.adm_id;
	quit;

proc contents varnum data=basic_oxy10;
run;


*(7)  Limit to variables of interest;

		proc sql;
		create table penult as
		select distinct 
			adm_id	 ,
			patientID,	
			admission_date	,
			admit_date_hosp	,
			discharge_date	,
			hospital_id	,
			year	,
			recordedDTS	,	recordedDT	,
			oxysupp_hospdate	,
			oxysupp_hospday	,
			oxysupp_hospday_orig	,
			o2DeviceMappedv3_vm	,
			o2DeviceMappedSTZ as o2DeviceMapped	,
			o2DeviceMappedSTZn as o2DeviceMappedn

		from basic_oxy10;
		quit;


/*(8)  Save as final  */
data raw.oxysupp_dly;
set penult;
run;



/**SAVE RAW DATASETS [for future reference] */
	   data tmp.oxysupp_raw_basic_oxy4;
	   set basic_oxy4;
	   run;   


	   data tmp.oxysupp_basic_oxy10;
	   set basic_oxy10;
	   run;



/*******************************************************************************************************************************************/
/*******************************************************************************************************************************************/


title 'FINAL QC for OXYSUPP_DLY dataset';

proc contents varnum data= raw.oxysupp_dly;;
run;

proc freq;
tables o2DeviceMappedSTZ/missing;
run;

