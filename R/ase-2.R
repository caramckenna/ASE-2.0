## ------------------------------------------------------------------------
## Name:         ase-2.R
## Author:       Cara McKenna
## Date Created: 09/12/2025
##
## Purpose:      Wrapper to run presumed serious infection and organ dysfunction
##               code to return final ASE dataset.  
##
## Output:       Dataset with one row per unique patientID/episodeID/ase_dt.
##
## Notes:        ASE requires calendar days. conMedDays may not reflect total 
##               consecutive med days because of windowing around anchor days.
## ------------------------------------------------------------------------

ase_2 <- function(edw_ver,
                  micro_path,
                  ep_dsn,
                  epmap_dsn,
                  days_co_ho = 7,
                  days_ho_ho = 14,
                  save_paths = list(
                    conmeds     = NULL,  # RDS path for meds_con_final (optional)
                    psi_detail  = NULL,  # RDS path for detailed PSI (optional)
                    psi_cohort  = NULL,  # RDS path for minimal PSI (optional)
                    ase         = NULL   # RDS path for final ASE (optional)
                  )) {
  
  t0 <- Sys.time()
  message("▶ Running PSI…")

  # 1) Build PSI (saves any requested artifacts via save_paths)
  psi <- ase_2_psi(
    edw_ver    = edw_ver,
    micro_path = micro_path,
    ep_dsn     = ep_dsn,
    epmap_dsn  = epmap_dsn,
    save_paths = save_paths
  )
  
  t1 <- Sys.time()
  message(sprintf("✓ PSI done in %.1f sec", as.numeric(difftime(t1, t0, units = "secs"))))
  
  
  message("▶ Running Organ Dysfunction…")
  ase_final <- ase_2_od(
    edw_ver    = edw_ver,
    psi_dsn    = psi, # pass the in-memory PSI cohort
    days_co_ho = days_co_ho,
    days_ho_ho = days_ho_ho
  )
  
  t2 <- Sys.time()
  message(sprintf("✓ OD done in %.1f sec (total %.1f sec)",
                  as.numeric(difftime(t2, t1, units = "secs")),
                  as.numeric(difftime(t2, t0, units = "secs"))))
  
  # 3) Optional save of final ASE
  if (!is.null(save_paths$ase)) {
    dir.create(dirname(save_paths$ase), recursive = TRUE, showWarnings = FALSE)
    saveRDS(ase_final, save_paths$ase)
    message("Saved final ASE to: ", save_paths$ase)
  }
  
  return(ase_final)
}
