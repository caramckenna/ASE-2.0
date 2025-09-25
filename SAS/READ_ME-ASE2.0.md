# READ_ME-ASE2.0

09/25/2025

This folder contains all of the information needed for the Adult Sepsis Event (ASE) 2.0 algorithm.  Step-by-step instructions are included below:

1. Reference the document “ASE_2.0_Overview of SAS Programs and Input Datasets_092425.xlsx” to ensure that all input datasets are structured correctly for the analysis.  See the Cover Sheet tab of the workbook for more information and clarifications about the input datasets and their expected structures.

2. Once the input datasets are prepared to match the documentation, place the input datasets in the empty folder “Run Analysis/Raw Datasets”.

3. Read the workbook "ASE_2.0_Overview of SAS Programs and Input Datasets_092425.xlsx” for a thorough explanation of each SAS program.  This workbook includes the sequence, purpose, inputs, and outputs of each SAS program.

4. In the folder “Reorganize Data”, open the file “0.0-user_inputs.sas” to add the necessary information for the remaining SAS programs to run properly.  This includes the full project path (ex: C:\Users\jdoe\Documents\…\ase_sepsis) and the names of each input dataset placed into the “Output” folder.  No additional changes beyond in this program should be needed to run the analysis.

5. Run the SAS programs in the order described in “ASE_2.0_Overview of SAS Programs and Input Datasets_092425.xlsx”, beginning with “0.0-user_inputs.sas”.  As the programs run, they will fill the folder “Output” with the input datasets that feed into the ASE algorithm (step 6).

6. In the folder “Run Analysis”, execute the ASE algorithm with the three SAS programs.  As the programs run, they will fill the folder “Working Datasets” with the final datasets.

7. If at any point there is an error while running the programs, first double-check that the structure of the input datasets exactly matches the structures outlined in “ASE_2.0_Overview of SAS Programs and Input Datasets_092425.xlsx”.  This workbook includes specific variable names, types, and values.

8. If there is an error that does not resolve itself after ensuring that the input datasets match the documentation, please send us an email with the specific error.  If it is a minor error, we will help resolve the issue by recommending a small fix.  If the error is larger, we will review the error more thoroughly and send an updated zip archive with the error fixed.

Please do not hesitate to reach out to us at the email addresses above for any questions about the analysis – we’re happy to help however possible.