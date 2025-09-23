## ------------------------------------------------------------------------
## Name:         ase-2-od.R
## Author:       Cara McKenna
## Date Created: 03/12/2025
##
## Purpose:      Function to identify organ dysfunction for CDC ASE Algorithm
##               and output an ASE dataset.
##
## Notes:        Output dataset is one row per patientID-episodeID-inf_onset_dt
##
#' @param input_data_dir Directory containing clinical data files (BP, medications, 
#'                       labs, etc.) with file naming pattern: {type}_{input_data_ver}.csv
#' @param input_data_ver Version identifier used in clinical data file names 
#'                       (e.g., "v1" creates files like "bp_v1.csv")
#' @param psi_dsn        Presumed serious infection dataset (data.frame or path to .Rds file).
#' @param days_co_ho     Minimum days between a community-onset (CO) and
#'                       hospital-onset (HO) sepsis event for the same patient
#'                       (default: 7 days)
#' @param days_ho_ho     Minimum days between sequential HO sepsis events for the
#'                       same patient (default: 14 days)             
## ------------------------------------------------------------------------

ase_2_od <- function(input_data_dir, input_data_ver, psi_dsn, 
                     days_co_ho = 7, days_ho_ho = 14) {
  # Load libraries
  library(tidyverse)
  library(data.table)
  library(lubridate)

  # PSI Data
  if (is.character(psi_dsn)) {
    if (grepl("\\.Rds$", psi_dsn, ignore.case = TRUE)) {
      psi <- readRDS(psi_dsn)
    } else {
      stop("psi_dsn must be a data.frame or a path to a .Rds")
    }
  } else if (inherits(psi_dsn, "data.frame")) {
    psi <- psi_dsn
  } else {
    stop("psi_dsn must be a data.frame or a path to a .Rds")
  }
  
  og_psi_rows <- nrow(psi)
  message("Loaded PSI dataset with ", og_psi_rows, " rows.")
  
  psi <- psi %>% 
    mutate(dischargeDispositionGroup=toupper(trimws(dischargeDispositionGroup)))
  
  # Organ Dysfunction: Cardiovascular ---------------------------------------
  
  # Need hourly BP
  bp <- fread(file.path(input_data_dir,paste0("bp_",input_data_ver,".csv")), colClasses = 'character', data.table = FALSE) %>% 
    distinct(patientID,recordedDTS,bpSystolic,bpDiastolic) %>% 
    inner_join(.,psi,by=c("patientID"),relationship = "many-to-many") %>% 
    mutate(recordedDTS = ymd_hms(recordedDTS),
           recordedDT   = date(recordedDTS),
           bpSystolic  = as.numeric(bpSystolic),
           bpDiastolic = as.numeric(bpDiastolic),
           map         = ((bpDiastolic*2) + bpSystolic) / 3
    ) %>% 
    filter(!is.na(recordedDTS),
           !is.na(bpSystolic),  bpSystolic  >= 0, bpSystolic  <= 300,
           !is.na(bpDiastolic), bpDiastolic >= 0, bpDiastolic <= 200,
           recordedDT >= (startDT - 1),                      # include day 0
           recordedDT <= hospitalDischargeDT,                # through discharge
    ) %>% 
    distinct(patientID,episodeID,recordedDTS,bpSystolic,bpDiastolic,map) 
  
  
  # look for bpSystolic < 90 OR map < 65 within 3 hrs of each other
  bp2 <- bp %>%
    filter(bpSystolic < 90 | map < 65) %>%
    arrange(patientID, episodeID, recordedDTS) %>%
    group_by(patientID,episodeID) %>%
    mutate(
      diffhr    = as.numeric(difftime(recordedDTS, lag(recordedDTS), units = "hours")),
      new_block = is.na(diffhr) | diffhr > 3, # start new block if >3h gap (or first row)
      indx      = cumsum(new_block)           # block id per patient
    ) %>%
    ungroup()
  
  # get time stamp when second reading occurs
  bp3 <- bp2 %>%
    group_by(patientID, episodeID, indx) %>%
    arrange(recordedDTS, .by_group = TRUE) %>%
    filter(n() >= 2) %>%
    slice(2) %>% 
    ungroup() %>%
    transmute(patientID, episodeID, indx, second_ts = recordedDTS)
  
  ## keep only readings in the same block AND occurring at/after second_ts.
  ## these are dates when bpSystolic < 90 OR map < 65 within 3 hrs of each other occur
  htn_dates <- bp2 %>%
    inner_join(bp3, by = c("patientID", "episodeID", "indx")) %>%  # align block + its second_ts
    filter(recordedDTS >= second_ts) %>%                        # at/after second reading only
    mutate(recordedDT = as.Date(recordedDTS)) %>%
    distinct(patientID, episodeID, recordedDT) %>%
    mutate(htn = 1L)
  
  # vasopressors
  vp <- fread(file.path(input_data_dir,paste0("vasopressors_",input_data_ver,".csv")), 
              colClasses = 'character', data.table = FALSE) %>% 
    filter(adminRouteMapped=="IV" & medNameMapped!="MIX") %>% 
    distinct(patientID,medicationTakenDTS,medNameMapped) %>% 
    inner_join(.,psi,by=c("patientID"),relationship = "many-to-many") %>% 
    mutate(medicationTakenDTS = ymd_hms(medicationTakenDTS),
           medicationTakenDT = date(medicationTakenDTS)
    ) %>% 
    filter(!is.na(medicationTakenDT),
           medicationTakenDT >= (startDT - 1),
           medicationTakenDT <= hospitalDischargeDT) %>% 
    distinct(patientID, episodeID, medicationTakenDT) %>%
    mutate(vp=1)
  
  
  # flag hypotension
  # new = no htn OR vasopressors in prior calendar day
  htnNew <- full_join(htn_dates,vp,by=c("patientID","episodeID",
                                        "recordedDT"="medicationTakenDT")) %>% 
    arrange(patientID, episodeID, recordedDT) %>% 
    group_by(patientID, episodeID) %>% 
    mutate(diffDays = abs(as.numeric(difftime(recordedDT, lag(recordedDT, default = first(recordedDT)),
                                              units = 'days'))),
           new = ifelse(diffDays==0 | diffDays > 1, 1,0)) %>%
    ungroup()
  
  
  htnNew2 <- htnNew %>% 
    filter(htn==1 & new==1) %>% 
    distinct(patientID, episodeID, recordedDT) %>% 
    mutate(new_htn=1)
  
  
  htnNew3 <- left_join(psi,htnNew2,by=c("patientID","episodeID"),
                       relationship = "many-to-many") %>%
    # within +/-1 day of infection onset date 
    filter(recordedDT >= inf_onset_dt-1 & recordedDT <= inf_onset_dt+1) %>% 
    distinct(patientID,episodeID,inf_onset_dt,new_htn,recordedDT)
  
  first_new_htn <- htnNew3 %>% 
    group_by(patientID, episodeID, inf_onset_dt, new_htn) %>%
    summarise(
      new_htn_dt = min(recordedDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  psi <- left_join(psi,first_new_htn,by=c("patientID","episodeID", "inf_onset_dt")) %>% 
    replace_na(list(new_htn=0))
  
  rm(bp,bp2,bp3,htn_dates,htnNew,htnNew2,htnNew3)
  
  
  # flag vasopressor initiation
  # new = none in prior day
  vpNew <- vp %>%
    arrange(patientID, episodeID, medicationTakenDT) %>% 
    group_by(patientID, episodeID) %>% 
    mutate(diffDays = abs(as.numeric(difftime(medicationTakenDT, lag(medicationTakenDT, default = first(medicationTakenDT)),
                                              units = 'days'))),
           new = ifelse(diffDays==0 | diffDays > 1, 1,0)) %>% 
    ungroup()
  
  
  vpNew2 <- vpNew %>% 
    filter(new==1) %>% 
    distinct(patientID, episodeID, medicationTakenDT) %>% 
    mutate(new_vp=1)
  
  
  vpNew3 <- left_join(psi,vpNew2,by=c("patientID","episodeID"),relationship = "many-to-many") %>%
    # within +/-1 day of infection onset date 
    filter(medicationTakenDT >= inf_onset_dt-1 & medicationTakenDT <= inf_onset_dt+1) %>% 
    select(patientID,episodeID,inf_onset_dt,new_vp,medicationTakenDT) %>% 
    distinct()
  
  first_new_vp <- vpNew3 %>% 
    group_by(patientID, episodeID, inf_onset_dt, new_vp) %>%
    summarise(
      new_vp_dt = min(medicationTakenDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  psi <- left_join(psi,first_new_vp,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(new_vp=0)) %>% 
    # create cardiovascular organ dysfunction
    mutate(od_cv = if_else(new_htn==1 | new_vp==1, 1,0))
  
  nrow(psi)
  
  # set date of cardiovascular organ dysfunction
  psi <- psi %>%
    group_by(patientID, episodeID, inf_onset_dt) %>%
    mutate(od_cv_dt = pmin(new_htn_dt, new_vp_dt, na.rm = TRUE)) %>%
    ungroup()
  
  nrow(psi)
  
  rm(vp,vpNew,vpNew2,vpNew3,first_new_vp,first_new_htn)
  
  
  
  # Organ Dysfunction: Respiratory ------------------------------------------
  
  o2Dev <- fread(file.path(input_data_dir,paste0("o2_devices_",input_data_ver,".csv")), colClasses = 'character', data.table = FALSE) %>% 
    # inner_join(.,epMap,by=c("patientID","patientEncounterID")) %>%
    inner_join(.,psi,by=c("patientID"),relationship = "many-to-many") %>%
    distinct(patientID,episodeID,startDT,hospitalDischargeDT,recordedDTS,displayNM,measureTXT,o2DeviceMappedv2) %>% 
    mutate(recordedDTS=ymd_hms(recordedDTS),
           recordedDT=date(recordedDTS)) %>%
    filter(!is.na(recordedDT),
           recordedDT >= (startDT - 1),
           recordedDT <= hospitalDischargeDT) %>% 
    mutate(# add recodes
           o2DeviceMappedv3=if_else(displayNM=="Vent Mode" & measureTXT %in% c('BiPAP', 'CPAP', 'NIV','NIV - CPAP', 'NIV - PS', 'NIV - ST'),
                                    "BIPAP", o2DeviceMappedv2))
  
  
  # Code adapted from STZ 
  # split O2 dev datasts
  # we don't need pump flow rows - they all have a corresponding device or vent mode record
  o2_device <- o2Dev %>% filter(displayNM=="O2 Device"| displayNM=="O2 Delivery Device" |displayNM=="O2 Delivery")  %>% 
    select(patientID,episodeID,recordedDTS,displayNM,measureTXT,o2DeviceMappedv3) %>% 
    distinct()
  
  ventMode <- o2Dev %>% filter(displayNM=="Vent Mode")  %>% 
    select(patientID,episodeID,recordedDTS,displayNM,measureTXT,o2DeviceMappedv3) %>% 
    distinct()
  
  o2DevSTZ <- full_join(o2_device,ventMode,by=c("patientID","episodeID","recordedDTS"),
                        suffix = c(".dev", ".vm"),relationship = "many-to-many") %>% 
    mutate(o2DeviceMappedSTZ=case_when(
      # 11/29/2022 Chanu said to map these as BIPAP
      # measureTXT.vm=="CPAP" & is.na(measureTXT.dev) ~ "BIPAP",
      # records missing o2DeviceMappedv2.x have no displayNM=="O2 Device" records so use mapped vent mode
      is.na(o2DeviceMappedv3.dev) ~ o2DeviceMappedv3.vm, 
      # otherwise use mapping from displayNM=="O2 Device" record
      TRUE ~ o2DeviceMappedv3.dev),
      o2DeviceMappedSTZn=case_when(
        o2DeviceMappedSTZ=="NONE" ~ 0,
        o2DeviceMappedSTZ=="NASAL CANNULA" ~ 1,
        o2DeviceMappedSTZ=="SIMPLE MASK" ~ 2,
        o2DeviceMappedSTZ=="OXYMIZER" ~ 3,
        o2DeviceMappedSTZ=="ADVANCED MASK" ~ 4,
        o2DeviceMappedSTZ=="HIGH FLOW" ~ 5,
        o2DeviceMappedSTZ=="BIPAP" ~ 6,
        o2DeviceMappedSTZ=="VENTILATOR" ~ 7,
        o2DeviceMappedSTZ=="ECMO" ~ 8
      )) %>% 
    distinct()
  
  o2DevSTZ <- o2DevSTZ %>% 
    filter(o2DeviceMappedSTZ %in% c("BIPAP","HIGH FLOW","VENTILATOR")) %>% 
    mutate(recordedDT = date(recordedDTS)) %>% 
    distinct(patientID,episodeID,recordedDT,o2DeviceMappedSTZ,o2DeviceMappedSTZn) %>% 
    left_join(.,psi,by=c("patientID","episodeID"),relationship = "many-to-many") %>% 
    distinct(patientID,episodeID,recordedDT,o2DeviceMappedSTZ,o2DeviceMappedSTZn,dx_osa,dx_rf) %>% 
    mutate(o2DeviceMappedSTZ2 = if_else(o2DeviceMappedSTZ=="BIPAP" & dx_osa==1 & dx_rf==0, 
                                        "BIPAP - excluded", o2DeviceMappedSTZ)
    )
  
  rm(o2Dev,o2_device,ventMode)
  gc()
  
  # flag new non-invasive ventilation or high flow nasal cannula 
  niv <- o2DevSTZ %>%
    filter(o2DeviceMappedSTZ2=="BIPAP" | o2DeviceMappedSTZ2=="HIGH FLOW") %>%
    distinct(patientID, episodeID, recordedDT) %>% 
    arrange(patientID, episodeID, recordedDT) %>%
    group_by(patientID, episodeID) %>%
    mutate(diffdays = as.numeric(difftime(recordedDT, lag(recordedDT, default = first(recordedDT)),
                                          units = 'days')),
           new = ifelse(diffdays==0 | diffdays > 1, 1,0),
           indx = cumsum(diffdays > 1)) %>% 
    ungroup()
  
  nivST <- niv %>% 
    filter(new==1)
  
  nivConDays <- niv %>% 
    group_by(patientID, episodeID, indx) %>%
    tally()
  
  niv2 <- left_join(nivST,nivConDays,by=c("patientID","episodeID","indx")) %>% 
    select(patientID, episodeID, nivST=recordedDT, connivdays=n) 
  

  # ALL invasive-ventilation calendar-dates for each patient
  vent_dates <- o2DevSTZ %>%
    filter(o2DeviceMappedSTZ == "VENTILATOR") %>%
    distinct(patientID, episodeID, ventDT = recordedDT)
  
  # Keep NIV/HF only when there was **no invasive vent on the previous calendar day**
  niv_prev_vent <- niv2 %>%
    left_join(vent_dates, by = c("patientID", "episodeID"), relationship = "many-to-many") %>%
    mutate(prev_vent = if_else(!is.na(ventDT) &
                                 (ventDT == (nivST - 1)), 1, 0)) %>%
    filter(prev_vent == 1) %>%
    distinct(patientID, episodeID, nivST)
  
  niv_new <- anti_join(niv2,niv_prev_vent,by=c("patientID", "episodeID", "nivST"))
  
  ## Qualifying NIV/HF cases
  ### (A) NIV/HF present >=2 consecutive days within sepsis event window
  niv_cons_in_window <- left_join(psi, niv_new, by = c("patientID", "episodeID"), 
                                  relationship = "many-to-many") %>%
    filter(nivST >= inf_onset_dt - 1 & nivST <= inf_onset_dt + 1,
           connivdays >= 2) %>%
    transmute(patientID, episodeID, inf_onset_dt, new_niv_hf_dt = nivST)
  
  ### Collapse to earliest
  niv_cons_first <- niv_cons_in_window %>% 
    group_by(patientID, episodeID, inf_onset_dt) %>%
    summarise(new_niv_hf_cons_dt = min(new_niv_hf_dt), .groups = "drop") %>%
    mutate(new_niv_hf_cons = 1L)
    

  ### (B) ASE 2.0v5 NEW RULE: NIV/HF present exactly 1 day within the sepsis event window,
  ### AND escalates to invasive ventilation the next calendar day
  niv_escalate <- niv_new %>%
    filter(connivdays == 1) %>%
    left_join(vent_dates, by = c("patientID", "episodeID"), relationship = "many-to-many") %>%
    filter(ventDT == (nivST + 1)) %>% # next-day invasive vent
    select(patientID, episodeID, nivST) %>%
    distinct()
  
  niv_escalate_in_window <- left_join(psi, niv_escalate, by = c("patientID", "episodeID"),
                               relationship = "many-to-many") %>%
    filter(nivST >= inf_onset_dt - 1 & nivST <= inf_onset_dt + 1) %>%
    transmute(patientID, episodeID, inf_onset_dt, new_niv_escalate_dt = nivST)
  
  ### Collapse to earliest
  niv_escalate_first <- niv_escalate_in_window %>%
    group_by(patientID, episodeID, inf_onset_dt) %>%
    summarise(new_niv_escalate_dt = min(new_niv_escalate_dt), .groups = "drop") %>%
    mutate(new_niv_escalate = 1L)
 
  ### Join both flags into PSI; build combined NIV/HF flag + date
  psi <- psi %>%
    left_join(niv_cons_first,     by = c("patientID","episodeID","inf_onset_dt")) %>%
    left_join(niv_escalate_first, by = c("patientID","episodeID","inf_onset_dt")) %>%
    mutate(
      new_niv_hf_cons   = replace_na(new_niv_hf_cons, 0L),
      new_niv_escalate  = replace_na(new_niv_escalate, 0L),
      new_niv_hf        = if_else(new_niv_hf_cons == 1L | new_niv_escalate == 1L, 1L, 0L),
      new_niv_hf_dt = case_when(
        !is.na(new_niv_hf_cons_dt)     & !is.na(new_niv_escalate_dt) ~ pmin(new_niv_hf_cons_dt, new_niv_escalate_dt),
        !is.na(new_niv_hf_cons_dt)                                     ~ new_niv_hf_cons_dt,
        !is.na(new_niv_escalate_dt)                                 ~ new_niv_escalate_dt,
        TRUE                                                         ~ as.Date(NA)
      )
    )
  
  
  rm(list = c(
    "niv","nivST","nivConDays","niv2",
    "vent_dates","niv_prev_vent","niv_new",
    "niv_cons_in_window","niv_cons_first",
    "niv_escalate","niv_escalate_in_window","niv_escalate_first"
  ))
  
  
  # ── flag **new** invasive-ventilation days ────────────────────────────────
  # “new” = no vent recorded on the previous calendar day
  vent_all <- o2DevSTZ %>%
    filter(o2DeviceMappedSTZ == "VENTILATOR") %>%
    distinct(patientID, episodeID, ventDT = recordedDT) %>%
    arrange(patientID, episodeID, ventDT) %>%
    group_by(patientID, episodeID) %>%
    mutate(
      diffdays = as.numeric(ventDT - lag(ventDT)),
      new      = if_else(is.na(diffdays) | diffdays > 1, 1L, 0L)
      ) %>%
    ungroup() %>%
    filter(new == 1L)
  
  vent_in_window <- left_join(psi, vent_all, by = c("patientID","episodeID"), 
                              relationship = "many-to-many") %>%
    # within ±1 calendar day of infection onset
    filter(ventDT >= inf_onset_dt - 1,
           ventDT <= inf_onset_dt + 1) %>%
    distinct(patientID, episodeID, inf_onset_dt, ventDT)
  
  first_vent <- vent_in_window %>%
    group_by(patientID, episodeID, inf_onset_dt) %>%
    summarise(new_vent_dt = min(ventDT), .groups = "drop") %>%
    mutate(new_vent = 1)
  
  
  psi <- left_join(psi,first_vent,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(new_vent=0)) %>% 
    # create respiratory organ dysfunction
    mutate(od_respiratory = if_else(new_niv_hf==1 | new_vent==1, 1,0))
  
  nrow(psi)
  
  # set date of respiratory organ dysfunction
  psi <- psi %>%
    group_by(patientID, episodeID, inf_onset_dt) %>%
    mutate(od_respiratory_dt = pmin(new_niv_hf_dt, new_vent_dt, na.rm = TRUE)) %>%
    ungroup()
  
  nrow(psi)
  
  rm(o2DevSTZ,vent_all,vent_in_window,first_vent)
  gc()
  
  # Lab Data Function -------------------------------------------------------
  
  importLabDat <- function(vdatNM,bestDef,minVal,maxVal,baseline=FALSE) {
    
    ldatF <- file.path(input_data_dir,paste0(vdatNM,"_",input_data_ver,".csv"))
    
    ldat_out <- fread(ldatF, colClasses = 'character', data.table = FALSE)
    
    # no time stamps
    ldat_out <- ldat_out %>%
      distinct(patientID,specimenTakenDTS,resultN) %>% 
      inner_join(.,psi,by=c("patientID"),relationship = "many-to-many") %>% 
      mutate(specimenTakenDTS = ymd_hms(specimenTakenDTS),
             specimenTakenDT  = date(specimenTakenDTS),
             resultN     = as.numeric(resultN)) %>% 
      filter(
        !is.na(specimenTakenDT),
        specimenTakenDT >= (startDT - 1),
        specimenTakenDT <= hospitalDischargeDT,
        !is.na(resultN), resultN >= minVal, resultN <= maxVal) %>%
      select(-specimenTakenDTS) %>% 
      distinct()
    
    # containers for optional outputs
    outList <- list(ldat = ldat_out)
    
    
    
    if (baseline) {
      
      # create baseline values
      
      # For community-onset infection, baseline lab values are defined as the best values during hospitalization
      baseline.co <- ldat_out %>% 
        filter(inf_type=="CO" & specimenTakenDT >= startDT & specimenTakenDT <= hospitalDischargeDT) %>% 
        select(patientID,episodeID,inf_onset_dt,bl=resultN) %>% 
        distinct()
      
      # For hospital-onset infection, baseline lab values are defined as the best values up to 2 days
      # prior to infection onset, including infection onset date
      baseline.ho <- ldat_out %>% 
        filter(inf_type=="HO" & specimenTakenDT >= inf_onset_dt-2 & specimenTakenDT <= inf_onset_dt) %>% 
        select(patientID,episodeID,inf_onset_dt,bl=resultN) %>% 
        distinct()
      
      
      # take best value
      # there won't be multiple inf_types within a inf_onset_dt
      if (bestDef=="max") {
        
        baseline <- bind_rows(baseline.co,baseline.ho) %>% 
          group_by(patientID,episodeID,inf_onset_dt) %>% 
          filter(bl==max(bl))
        
      }
      
      if (bestDef=="min") {
        
        baseline <- bind_rows(baseline.co,baseline.ho) %>% 
          group_by(patientID,episodeID,inf_onset_dt) %>% 
          filter(bl==min(bl))
        
      }
      
      outList$baseline <- baseline
    } 
    
    return(if (length(outList) == 1) outList$ldat else outList)
  }
  
  
  
  # Organ Dysfunction: Metabolic --------------------------------------------
  
  lac <- importLabDat("lactate","min",0,100)
  
  # get the worst (max) lactate for each patient-day
  lac_daily <- lac %>%
    group_by(patientID, episodeID, specimenTakenDT) %>%
    summarise(day_max = max(resultN), .groups = "drop")
  
  # bring in the worst value from the previous calendar day
  lac_daily <- lac_daily %>%
    mutate(prevDT = specimenTakenDT - 1) %>%
    left_join(
      lac_daily %>% select(patientID, episodeID, prevDT = specimenTakenDT, prev_max = day_max),
      by = c("patientID", "episodeID", "prevDT")
    )
  
  # flag OD days: >2.0 mmol/L AND (rising vs prior day OR no prior-day value)
  lac_in_window <- lac_daily %>%
    filter(day_max > 2, 
           (is.na(prev_max) | day_max > prev_max)) %>%   # rising OR no prior value
    left_join(psi, by = c("patientID","episodeID"), relationship = "many-to-many") %>%
    # within ±1 day of infection onset
    filter(specimenTakenDT >= inf_onset_dt - 1,
           specimenTakenDT <= inf_onset_dt + 1) %>%
    distinct(patientID, episodeID, inf_onset_dt, specimenTakenDT) %>%
    mutate(od_metabolic = 1)
  
  
  first_lac <- lac_in_window %>% 
    group_by(patientID, episodeID, inf_onset_dt, od_metabolic) %>%
    summarise(
      od_metabolic_dt = min(specimenTakenDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  
  psi <- left_join(psi,first_lac,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(od_metabolic=0))
  
  rm(lac,lac_daily,lac_in_window,first_lac)
  
  
  
  # Organ Dysfunction: Renal ------------------------------------------------
  
  # Best creatinine = min
  cr.lst <- importLabDat("creatinine","min",0,20,baseline=TRUE)
  cr <- cr.lst$ldat
  cr.bl <- cr.lst$baseline
  
  
  od_cr <- left_join(cr,cr.bl,by=c("patientID","episodeID","inf_onset_dt"),relationship = "many-to-many") %>% 
    # exclude patients with end stage renal disease
    filter(dx_esrd==0) %>% 
    # Assume normal baseline values for community-onset sepsis if death/discharge to hospice occurs, 
    # unless they have moderate/severe chronic renal failure -> use baseline values
    # normal creatinine value [1.18 for male; 1.02 for female]
    mutate(
      # sex-specific normal creatinine
      normal_cr = case_when(
        sex == "MALE"   ~ 1.18,
        sex == "FEMALE" ~ 1.02,
        TRUE            ~ NA_real_
      ),
      bl2 = case_when(
        inf_type == "CO" &
          dischargeDispositionGroup %in% c("DEAD","HOSPICE") &
          dx_renal_poa == 0 ~ coalesce(pmin(normal_cr, bl, na.rm = TRUE), normal_cr, bl),
        TRUE ~ bl
      ),

      ratio = if_else(bl2 > 0, resultN / bl2, NA_real_),
      
      od_renal = as.integer(!is.na(ratio) & ratio >= (2 - 1e-8) & resultN >  normal_cr),
    )
  
  od_cr_in_window <- od_cr %>% 
    # within +/-1 day of infection onset date 
    filter(od_renal==1,
           specimenTakenDT >= inf_onset_dt-1,
           specimenTakenDT <= inf_onset_dt+1) %>% 
    distinct(patientID,episodeID,inf_onset_dt,od_renal,specimenTakenDT)
  
  first_od_cr <- od_cr_in_window %>% 
    group_by(patientID, episodeID, inf_onset_dt, od_renal) %>%
    summarise(
      od_renal_dt = min(specimenTakenDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  psi <- left_join(psi,first_od_cr,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(od_renal=0))
  
  rm(cr.lst,cr,cr.bl,od_cr,od_cr_in_window,first_od_cr)
  
  
  
  # Organ Dysfunction: Hepatic ----------------------------------------------
  
  # Best bilirubin = min
  tbil.lst <- importLabDat("total_bilirubin","min",0,50,baseline=TRUE)
  tbil <- tbil.lst$ldat
  tbil.bl <- tbil.lst$baseline
  
  od_hep <- left_join(tbil, tbil.bl,
                      by = c("patientID","episodeID","inf_onset_dt"),
                      relationship = "many-to-many") %>%
    # exclude mod/severe liver disease or hemolytic anemia
    filter(dx_liver_poa == 0, dx_ha_poa == 0) %>%
    mutate(
      # override baseline only for CO with death/hospice
      bl2 = case_when(
        inf_type == "CO" &
          dischargeDispositionGroup %in% c("DEAD","HOSPICE") ~ 0.5,
        TRUE ~ bl
      ),
      # compute ratio for change, avoid dividing by zero
      ratio = if_else(bl2 > 0, resultN / bl2, NA_real_),
      # hepatic OD: total bili >= 2.0 AND >= 2× baseline
      od_hepatic = as.integer(!is.na(ratio) & ratio >= (2 - 1e-8) & resultN >= 2)
    )
  
  od_hep_in_window <- od_hep %>% 
    # within +/-1 day of infection onset date 
    filter(od_hepatic==1,
           specimenTakenDT >= inf_onset_dt-1,
           specimenTakenDT <= inf_onset_dt+1) %>% 
    distinct(patientID,episodeID,inf_onset_dt,od_hepatic,specimenTakenDT)
  
  first_od_hep <- od_hep_in_window %>% 
    group_by(patientID, episodeID, inf_onset_dt, od_hepatic) %>%
    summarise(
      od_hepatic_dt = min(specimenTakenDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  
  psi <- left_join(psi,first_od_hep,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(od_hepatic=0))
  
  
  rm(tbil.lst,tbil,tbil.bl,od_hep,od_hep_in_window,first_od_hep)
  
  
  
  # Organ Dysfunction: Coagulation ------------------------------------------
  
  # Best platelets = max
  plt.lst <- importLabDat("platelets","max",0,3000,baseline=TRUE)
  plt <- plt.lst$ldat
  plt.bl <- plt.lst$baseline
  
  od_coag <- left_join(plt, plt.bl,
                       by = c("patientID","episodeID","inf_onset_dt"),
                       relationship = "many-to-many") %>% 
    # exclude hematologic/solid malignancy
    filter(dx_cancer == 0) %>% 
    mutate(
      # override baseline only for CO with death/hospice
      bl2 = case_when(
        inf_type == "CO" &
          dischargeDispositionGroup %in% c("DEAD","HOSPICE") ~ 200,
        TRUE ~ bl
      ),
      # protect against divide-by-zero
      ratio = if_else(bl2 > 0, resultN / bl2, NA_real_),
      # OD if baseline >=100, >=50% drop (ratio ≤ 0.5) and absolute <100
      # add tiny tolerance for floating point
      od_coagulation = as.integer(!is.na(ratio) &
                                    bl2 >= 100 &
                                    ratio <= (0.5 + 1e-8) &
                                    resultN < 100)
    )
  
  od_coag_in_window <- od_coag %>% 
    # within +/-1 day of infection onset date 
    filter(od_coagulation==1,
           specimenTakenDT >= inf_onset_dt-1,
           specimenTakenDT <= inf_onset_dt+1) %>% 
    distinct(patientID,episodeID,inf_onset_dt,od_coagulation,specimenTakenDT)
  
  first_od_coag <- od_coag_in_window %>% 
    group_by(patientID, episodeID, inf_onset_dt, od_coagulation) %>%
    summarise(
      od_coagulation_dt = min(specimenTakenDT, na.rm = TRUE),
      .groups = "drop"
    )
  
  psi <- left_join(psi,first_od_coag,by=c("patientID","episodeID","inf_onset_dt")) %>% 
    replace_na(list(od_coagulation=0))
  
  
  
  # Final ASE Dataset -------------------------------------------------------
  
  cdc.ase <- psi %>% 
    mutate(ase = if_else(od_cv==1 | od_respiratory==1 | od_metabolic==1 | 
                           od_renal==1 | od_hepatic==1 | od_coagulation==1, 1, 0))
  
  if (nrow(cdc.ase) != og_psi_rows) {
    warning(
      sprintf(
        "Row count mismatch: cdc.ase=%s, PSI loaded=%s (Δ=%s).",
        format(nrow(cdc.ase), big.mark = ","),
        format(og_psi_rows, big.mark = ","),
        format(nrow(cdc.ase) - og_psi_rows, big.mark = ",")
      )
    )
  } else {
    message("Row count OK: cdc.ase matches PSI rows (", og_psi_rows, ").")
  }
  

  # set date of ASE
  cdc.ase <- cdc.ase %>%
    filter(ase == 1) %>% 
    group_by(patientID, episodeID, inf_onset_dt) %>%
    mutate(
      # earliest organ-dysfunction date among components
      od_dt  = pmin(od_cv_dt, od_respiratory_dt, od_metabolic_dt,
                    od_renal_dt, od_hepatic_dt, od_coagulation_dt, na.rm = TRUE),
      # ASE date = earliest of infection onset or any OD
      ase_dt = pmin(inf_onset_dt, od_dt, na.rm = TRUE),
      
      # hospital-day index (startDT is day 1) for each criterion
      ase_day  = as.numeric(ase_dt - startDT) + 1,
      # "any < 4" vs "all >= 4" implemented via the minimum observed day
      ase_type = if_else(ase_day < 4, "CO", "HO")
    ) %>%
    ungroup()
  
  nrow(cdc.ase)
  nrow(distinct(cdc.ase,patientID,episodeID,inf_onset_dt))
  
  # ── if multiple CO ASEs, only keep earliest per encounter ────────────────────────────
  cdc.ase2 <- cdc.ase %>% 
    arrange(patientID, episodeID, ase_dt) %>%
    group_by(patientID, episodeID) %>%
    mutate(co_rank = if_else(ase_type == "CO",
                             row_number(),                         
                             NA_integer_)) %>%
    filter(is.na(co_rank) | co_rank == 1L) %>%  # drop CO_rank >1
    select(-co_rank) %>%
    ungroup()
  
  nrow(cdc.ase2)
  nrow(distinct(cdc.ase2,patientID,episodeID,inf_onset_dt))
  
  # ── De-duplicate closely spaced sepsis events ───────────────────────────────
  # Rules
  #   Any CO / HO pair must be ≥ 7 days apart
  #   HO events must be ≥ 14 days apart from the previous HO event
 
  setDT(cdc.ase2)
  setorder(cdc.ase2, patientID,episodeID, ase_dt)
  
  cdc.ase3 <- cdc.ase2[, {
    keep <- logical(.N)
    last_dt <- as.IDate(NA)
    last_type <- NA_character_
    
    for (i in seq_len(.N)) {
      cur_dt <- ase_dt[i]
      cur_type <- ase_type[i]
      
      if (is.na(last_dt)) {
        keep[i] <- TRUE
        last_dt <- cur_dt
        last_type <- cur_type
        next
      }
      
      gap_days <- as.integer(cur_dt - last_dt)
      need_gap <- if (cur_type == "HO" && last_type == "HO") {
        days_ho_ho
      } else if (!is.na(cur_type) && !is.na(last_type) && cur_type != last_type) {
        days_co_ho
      } else {
        0L
      }
      
      if (gap_days >= need_gap) {
        keep[i] <- TRUE
        last_dt <- cur_dt
        last_type <- cur_type
      }
    }
    .SD[keep]
  }, by = c("patientID", "episodeID")]
  
  nrow(cdc.ase3)
  nrow(distinct(cdc.ase3,patientID,episodeID,inf_onset_dt))
  
  return(cdc.ase3)
}
