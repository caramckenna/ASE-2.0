*********************************************************************************
* PROGRAM: 	0.0-user_inputs.sas                                               	*
* DATE: 	09/23/2025      
* BY:   	Christina Chan
* PURPOSE:  Set up standard libname directories 
*			to run Sepsis Algorithm SAS programs for ASE 2.0

*                                                                               *
*********************************************************************************;



/*******************************************************************************/
/* User Inputs for running programs:                                           */
/*******************************************************************************/

/* Note: The project path folder should have the following four sub-folders.
			These have been included in the zip file by default.

	Raw Datasets - Includes the following input datasets: 
			 -basic
			 -blood_culture
			 -blood_culture_dxpoa_inf
			 -comfortcare
			 -diagnosis
			 -diagnosis_dxpoa_inf
			 -diagnosis_flag
			 -encounters
			 -laboratory
			 -medications
			 -oxysupp_dly
			 -vitals_bp_hotn



	Working Datasets - Will include working datasets of the code
	Output Tables - Will include results tables for final reporting 
	SAS Code - Includes all SAS scripts

*/

/* Set variable p1 to project folder path. 
	Ex: p1 = C:\Users\...\CDC National Sepsis Surveillance Project\ */



%let p1 =Z:\ehr_sepsis_algorithm\Reorganize data;
%let p2 =Z:\ehr_sepsis_algorithm\Run Analysis;

/******************************************************************************
* Standard library definitions
******************************************************************************/

/* TMP Directory */
%let indir = &p1.\Tmp;
libname tmp "&indir.";

/* Input Directory (RAW) */
%let indir = &p1.\Output;
libname raw "&indir.";

/* Output Directory  (SEPSIS)*/
%let outdir = &p2.\Working Datasets;
libname sepsis "&outdir.";

/* Table Results Directory */
%let resdir = &p2.\Output Tables;



*libname for FINAL;
libname tmp   'Z:\XXX\Reorganize Data v6.3\Tmp';
libname raw   'Z:\XXX\Reorganize Data v6.3\Output';
libname sepsis 'Z:\XXX\Run analysis\working datasets';
