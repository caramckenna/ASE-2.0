## ------------------------------------------------------------------------
## Name:         ase-2-psi.R
## Author:       Cara McKenna
## Date Created: 03/12/2025
##
## Purpose:      Create CDC ASE Algorithm presumed serious infection
##               cohort.
##
## Output:       Dataset with one row per unique patientID/episodeID/inf_onset_dt.
##
## Notes:        ASE requires calendar days. conMedDays may not reflect total 
##               consecutive med days because of windowing around anchor days.
## ------------------------------------------------------------------------

ase_2_psi <- function(edw_ver, micro_path, ep_dsn, epmap_dsn,
                      save_paths = list(psi_cohort = NULL, conmeds = NULL, psi_detail = NULL)) {
  
  library(tidyverse)
  library(data.table)

  # Setup paths
  edw_main_dir  <- "/data/tide/data/edw"
  edw_data_dir  <- file.path(edw_main_dir, edw_ver)
  ase_mapping_dir <- "/data/tide/projects/ASE/mapping"
  
  # Load mapping files
  ase_dx_path   <- file.path(ase_mapping_dir, "ase-icd10-codes.csv")
  ahrq_dx_path  <- file.path(ase_mapping_dir, "ase-ahrq-icd10-codes.csv")
  ase_meds_path <- file.path(ase_mapping_dir, "ase-medications-list.csv")

  # ep <- readRDS(ep_dsn)
  
  if (is.character(ep_dsn)) {
    if (grepl("\\.Rds$", ep_dsn, ignore.case = TRUE)) {
      ep_dsn <- readRDS(ep_dsn)
    } else {
      stop("ep_dsn must be a data.frame or a path to a .Rds or .csv file")
    }
  } else if (!inherits(ep_dsn, "data.frame")) {
    stop("ep_dsn must be a data.frame or a file path")
  }
  

  # get patientEncounterIDs from all episodes 
  if (is.character(epmap_dsn)) {
    if (grepl("\\.Rds$", epmap_dsn, ignore.case = TRUE)) {
      epMap <- readRDS(epmap_dsn)
    } else if (grepl("\\.csv$", epmap_dsn, ignore.case = TRUE)) {
      epMap <- fread(epmap_dsn, colClasses = 'character', data.table = FALSE)
    } else {
      stop("epmap_dsn must be a path to a .Rds or .csv file")
    }
  } 
  
  # Maps patientID -> EMPI & episodeID -> patientEncounterID
  epMap <- epMap %>% 
    distinct(patientID,empi,episodeID,patientEncounterID)
  
  # map patientID -> MRN
  mrn <- fread(file.path(edw_data_dir,paste0("mrn_",edw_ver,".csv")), colClasses = 'character', 
               data.table = FALSE) 
 
  # map patientID -> MRN -> EMPI
  mrn_map <- inner_join(epMap,mrn,by="patientID",relationship = "many-to-many") %>% 
    mutate(mrn = suppressWarnings(as.numeric(mrn))) %>% 
    filter(!is.na(mrn)) %>%
    distinct(patientID,mrn,empi)

  rm(mrn)

  # Blood Cultures ----------------------------------------------------------
  bcx <- fread(micro_path, colClasses = 'character', data.table = FALSE) %>% 
    filter(site_clean == "BLOOD") %>%
    mutate(
      mrn = suppressWarnings(as.numeric(MRN)),
      coll_datetime = ymd_hms(coll_datetime),
      bcxCollDT = date(coll_datetime)
    ) %>%
    filter(!is.na(coll_datetime))
  
  # Join by patientEncounterID (CSN)
  bcx_by_csn <- bcx %>%
    inner_join(epMap, by = c("CSN" = "patientEncounterID"), relationship = "many-to-many") %>%
    mutate(bcx_match_type = "CSN") %>% 
    distinct(patientID,bcxCollDT,bcx_match_type)
  
  # Join by EMPI
  bcx_by_empi <- bcx %>%
    inner_join(mrn_map, by ="mrn", relationship = "many-to-many") %>%
    mutate(bcx_match_type = "EMPI") %>% 
    distinct(patientID,bcxCollDT,bcx_match_type)
  
  # combine both 
  bcx_all <- bind_rows(bcx_by_csn,bcx_by_empi) %>%
    distinct()
  
  bcx <- left_join(ep_dsn,bcx_all,by=c("patientID"),relationship = "many-to-many") %>% 
    filter(bcxCollDT >= startDT-1 & bcxCollDT <= hospitalDischargeDT) %>% 
    distinct(patientID,episodeID,bcxCollDT,bcx_match_type)
  
  # collapse to one bcx_match_type per bcxCollDT
  bcx <- bcx %>%
    group_by(patientID, episodeID, bcxCollDT) %>%
    reframe(bcx_match_type = if (n_distinct(bcx_match_type) > 1) "BOTH" else first(bcx_match_type))

  
  # will make multiple rows per episode if multiple bcxs within episode
  # one row per bcxCollDt
  ep.bcx <- left_join(ep_dsn,bcx,by=c("patientID","episodeID")) %>% 
    mutate(bcxCollday = as.numeric(bcxCollDT - startDT)+1)
  
  rm(ep_dsn,bcx_by_empi,bcx_by_csn,bcx)
    
  # Dx codes ----------------------------------------------------------------
  
  asedxMap <- fread(ase_dx_path) %>%
    distinct(poa,icd10_cm_dx,dxcat_broad)
  
  
  ahrqdxMap <- fread(ahrq_dx_path) %>% 
    select(icd_10_cm_code,infectious_category_1) %>% 
    distinct() %>% 
    mutate(icd10np= str_squish(str_remove_all(icd_10_cm_code, "[[:punct:]]"))) %>%
    filter(infectious_category_1!="")
  
  
  dx <- fread(file.path(edw_data_dir,paste0("discharge_dx_",edw_ver,".csv")),colClasses = 'character') %>% 
    inner_join(.,epMap,by=c("patientID","patientEncounterID")) %>%
    mutate(icd10np= str_squish(str_replace_all(icd10, "[[:punct:]]", ""))) %>%
    distinct(patientID,episodeID,lineNBR,presentOnAdmissionDSC,icd10,icd10np)
  
  dx.ase <- inner_join(dx,asedxMap,by=c("icd10np"="icd10_cm_dx"))
  
  dx.ahrq <- inner_join(dx,ahrqdxMap,by="icd10np") %>% 
    filter(lineNBR=="1" & toupper(presentOnAdmissionDSC)=="YES") %>% 
    mutate(dx_ahrqinf_poa=1) %>% 
    distinct(patientID,episodeID,dx_ahrqinf_poa)
  
  ep.bcx <- left_join(ep.bcx,dx.ahrq,by=c("patientID","episodeID")) %>%
    replace_na(list(dx_ahrqinf_poa=0))
  
  
  dx.renal <- dx.ase %>% 
    # has to be POA
    filter(dxcat_broad=="elix_renal" & toupper(presentOnAdmissionDSC)=="YES") %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_renal_poa = 1)
  
  ep.bcx <- left_join(ep.bcx,dx.renal,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_renal_poa=0))
  
  # End stage renal disease
  dx.esrd <- dx %>% 
    filter(icd10=="N18.6") %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_esrd = 1)
  
  ep.bcx <- left_join(ep.bcx,dx.esrd,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_esrd=0))
  
  dx.liver <- dx.ase %>% 
    # has to be POA
    filter(dxcat_broad=="elix_liver" & toupper(presentOnAdmissionDSC)=="YES") %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_liver_poa = 1)
  
  ep.bcx <- left_join(ep.bcx,dx.liver,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_liver_poa=0))
  
  
  dx.cancer <- dx.ase %>% 
    filter(dxcat_broad=="elix_cancer") %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_cancer = 1)
  
  ep.bcx <- left_join(ep.bcx,dx.cancer,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_cancer=0))
  
  # POA hemolytic anemia (D55x, D56x, D57x, D58x, and D59x) for hepatic organ dysfunction
  dx.ha <- dx %>% 
    filter(toupper(presentOnAdmissionDSC)=="YES" & str_detect(icd10np,"^D55|^D56|^D57|^D58|^D59")) %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_ha_poa = 1)
  
  ep.bcx <- left_join(ep.bcx,dx.ha,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_ha_poa=0))
  
  dx.osa <- dx.ase %>% 
    filter(dxcat_broad=="dx_osa") %>% 
    distinct(patientID,episodeID) %>% 
    mutate(dx_osa = 1) 
  
  ep.bcx <- left_join(ep.bcx,dx.osa,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_osa=0))
  
  dx.rf <- dx.ase %>% 
    filter(dxcat_broad=="dx_rf") %>%  
    distinct(patientID,episodeID) %>% 
    mutate(dx_rf = 1) 
  
  ep.bcx <- left_join(ep.bcx,dx.rf,by=c("patientID","episodeID")) %>% 
    replace_na(list(dx_rf=0))
  
  
  rm(dx,dx.ase,dx.ahrq,dx.cancer,dx.ha,dx.liver,dx.renal,dx.osa,dx.rf)
  
 
  # Create infection anchor date --------------------------------------------

  # Infection anchor date = day of blood culture 
  # or day 1 if infection as principal diagnosis and no blood culture before day 4
  
  # identify which patients have blood cultures in days 0-3
  early_bcx <- ep.bcx %>%
    filter(!is.na(bcxCollday) & bcxCollday >= 0 & bcxCollday <= 3) %>%
    distinct(patientID, episodeID)
  
  # Part A: Blood culture-based anchor dates (for ALL blood cultures)
  onset_a <- ep.bcx %>% 
    filter(!is.na(bcxCollDT)) %>% 
    mutate(inf_anchor_dt = bcxCollDT,
           inf_anchor_src = "BCX") %>% 
    select(patientID, episodeID, startDT, hospitalDischargeDT, 
           dischargeDispositionGroup, deathDT_derived, 
           inf_anchor_dt,dx_ahrqinf_poa,inf_anchor_src) %>% 
    distinct()
  
  # Part B: Diagnosis-based anchor dates 
  # ONLY for patients with dx_ahrqinf_poa=1 AND no blood culture in days 0-3
  onset_b <- ep.bcx %>% 
    filter(dx_ahrqinf_poa == 1) %>%
    # Exclude patients who had ANY blood culture in days 0-3
    anti_join(early_bcx, by = c("patientID", "episodeID")) %>%
    mutate(inf_anchor_dt = startDT,
           inf_anchor_src = "DX") %>% 
    select(patientID, episodeID, startDT, hospitalDischargeDT, 
           dischargeDispositionGroup, deathDT_derived, 
           inf_anchor_dt, dx_ahrqinf_poa,inf_anchor_src) %>% 
    distinct()
  
  # Combine both parts
  # population of encounters with a blood culture or AHRQ POA dx code
  psi.pop <- bind_rows(onset_a, onset_b) %>% 
    distinct()
    
  nrow(psi.pop)
  nrow(distinct(psi.pop,patientID,episodeID,inf_anchor_dt))
  
  
  # Qualifying Antibiotic Days (QAD) ----------------------------------------
  
  # meds of interest
  asemeds <- fread(ase_meds_path) %>% 
    mutate(medname2=str_replace_all(toupper(med_name), "_| ", "-"),
           medname2=str_squish(toupper(medname2)),
           medname_route=paste(medname2,route,sep = "-")) %>%
    filter(medname2!="") %>% 
    distinct(med_name,medname2,medname_route,med_category)
  
  
  abx <- fread(file.path(edw_data_dir,paste0("abx_",edw_ver,".csv")), colClasses = 'character', data.table = FALSE) %>% 
    select(patientID,medicationTakenDTS,adminRouteMapped,medNameMapped) %>% 
    inner_join(.,psi.pop,by=c("patientID"),relationship = "many-to-many") %>%
    distinct(patientID,episodeID,startDT,hospitalDischargeDT,medicationTakenDTS,adminRouteMapped,medNameMapped)
    
  
  othmed <- fread(file.path(edw_data_dir,paste0("antifungals_antivirals_",edw_ver,".csv")), colClasses = 'character', data.table = FALSE) %>% 
    select(patientID,medicationTakenDTS,adminRouteMapped,medNameMapped) %>% 
    inner_join(.,psi.pop,by=c("patientID"),relationship = "many-to-many") %>%
    distinct(patientID,episodeID,startDT,hospitalDischargeDT,medicationTakenDTS,adminRouteMapped,medNameMapped)
    
  meds <- bind_rows(abx,othmed) %>% 
    mutate(medNameMapped=str_replace_all(toupper(medNameMapped), "_| ", "-"),
           # treat IM the same as IV
           adminRouteMapped2=if_else(adminRouteMapped=="IM","IV",adminRouteMapped),
           medNameMapped_route=paste(medNameMapped,adminRouteMapped2,sep = "-")) %>% 
    filter(medNameMapped_route %in% asemeds$medname_route) %>%
    mutate(medicationTakenDTS=ymd_hms(medicationTakenDTS),
           medicationTakenDT=date(medicationTakenDTS),
           # create version in Boston time to use with comfort care data
           medicationTakenDT_ET = date(with_tz(medicationTakenDTS, tz = "America/New_York"))
    ) %>% 
    filter(!is.na(medicationTakenDT),
           medicationTakenDT >= startDT-1,
           medicationTakenDT <= hospitalDischargeDT) %>%
    distinct(patientID,episodeID,medicationTakenDT,medicationTakenDT_ET,medNameMapped,adminRouteMapped2)
  
  meds <- meds %>% 
    mutate(med=if_else(medNameMapped=="VANCOMYCIN",paste("VANCOMYCIN",adminRouteMapped2,sep = "-"),
              medNameMapped),
           is_parenteral = adminRouteMapped2=="IV") %>% 
    distinct(patientID,episodeID,medicationTakenDT,medicationTakenDT_ET,adminRouteMapped2,med,is_parenteral)
  
  rm(abx,othmed)
  
  
  # Find Consecutive Days of Medications ------------------------------------
  
  ## ---- QAD TIMER (base R) ----
  qad_t0 <- proc.time()
  .qad_mark <- function(msg) {
    e <- (proc.time() - qad_t0)[["elapsed"]]
    message(sprintf("[QAD] %-32s  %7.1f s", msg, e))
  }
  
  ## ===== START QAD =====
  .qad_mark("start")
  
  # 1. Identify “new” IV/IM meds (no SAME med in the previous 2 days)
  #    med-specific day series
  meds_flagged <- meds %>%
    arrange(patientID, episodeID, med, medicationTakenDT) %>%
    group_by(patientID, episodeID, med) %>%
    mutate(
      prev_dt   = lag(medicationTakenDT),
      gap       = as.integer(medicationTakenDT - prev_dt),
      # new if no same-med in prior 2 days (any route)
      new_any   = as.integer(is.na(gap) | gap > 2L),
      # seeds must be parenteral + new
      new_paren = as.integer(is_parenteral & new_any)
    ) %>%
    ungroup() %>%
    select(patientID, episodeID, med, medicationTakenDT, medicationTakenDT_ET, new_any, new_paren)
  
  # 2. Seed QAD only from “new” med starts that fall within ±1 day of the infection ANCHOR date
  qad_seeds <- psi.pop  %>%
    select(patientID, episodeID, inf_anchor_dt, hospitalDischargeDT) %>%
    inner_join(
      meds_flagged %>% filter(new_paren == 1L) %>%
        transmute(patientID, episodeID, med, seed_dt = medicationTakenDT),
      by = c("patientID","episodeID"),
      relationship = "many-to-many"
    ) %>%
    filter(seed_dt >= inf_anchor_dt - 1, 
           seed_dt <= inf_anchor_dt + 1) %>%
    distinct(patientID, episodeID, inf_anchor_dt, hospitalDischargeDT, med, seed_dt)
  
  qad_seeds <- as.data.table(qad_seeds)
  
  # keep the seeded patient list for subsequent restriction
  seed_pts_dt <- unique(qad_seeds[, .(patientID,episodeID)])
  
  # 3. Build per-encounter scan window: [-5, +7] days around the infection anchor
  scan_bounds <- psi.pop %>%
    select(patientID, episodeID, inf_anchor_dt) %>%
    mutate(win_start = inf_anchor_dt - 5L,
           win_end   = inf_anchor_dt + 7L)
  
  # Keep only med days inside any window for that encounter
  meds_flagged_win <- meds_flagged %>%
    inner_join(scan_bounds, by = c("patientID","episodeID"), relationship = "many-to-many") %>%
    filter(medicationTakenDT >= win_start,
           medicationTakenDT <= win_end) %>%
    distinct()
  
  meds_flagged_win <- as.data.table(meds_flagged_win)
  
  # 4. Build a per-patient daily panel (meds_today, new_today_any, end_ET), seeded patients only
  daily0_dt <- meds_flagged_win[
    seed_pts_dt, on = c("patientID","episodeID"), nomatch = 0
  ][, .(
    meds_today    = list(sort(unique(med))),
    new_today_any = list(sort(unique(med[new_any == 1L]))),
    end_ET        = max(medicationTakenDT_ET)
  ),
  by = .(patientID, episodeID, medicationTakenDT)
  ]
  
  # "complete" the day sequence per patient (fill missing days)
  rng_dt <- daily0_dt[, .(min_dt = min(medicationTakenDT), max_dt = max(medicationTakenDT)), by = c("patientID","episodeID")]
  full_dt <- rng_dt[, .(medicationTakenDT = seq(min_dt, max_dt, by = "1 day")), by = c("patientID","episodeID")]
  
  daily_dt <- full_dt[daily0_dt, on = .(patientID, episodeID, medicationTakenDT)]
  # replace missing lists with empty character vectors
  daily_dt[is.na(meds_today),    meds_today    := replicate(.N, character(0), simplify = FALSE)]
  daily_dt[is.na(new_today_any), new_today_any := replicate(.N, character(0), simplify = FALSE)]
  
  # nest per patient-episodeID (structure compatible with extend_from_seed())
  daily_by_pt_dt <- daily_dt[, .(
    dtbl = list(data.table::data.table(
      medicationTakenDT = medicationTakenDT,
      meds_today        = meds_today,
      new_today_any     = new_today_any,
      end_ET            = end_ET
    ))
  ), by = c("patientID","episodeID")]
  
  .qad_mark("built daily tables")
  
  # Streak expander
  extend_from_seed <- function(dtbl, seed_dt, discharge_dt, seed_med) {
    dates <- dtbl$medicationTakenDT
    idx   <- function(d) match(d, dates)
    get_meds    <- function(d){ i <- idx(d); if (is.na(i)) character(0) else dtbl$meds_today[[i]] }
    get_new_any <- function(d){ i <- idx(d); if (is.na(i)) character(0) else dtbl$new_today_any[[i]] }
    
    last_date <- if (is.na(discharge_dt)) max(dates) else min(max(dates), discharge_dt)
    if (is.na(idx(seed_dt))) {
      return(tibble::tibble(conMedStartDT = seed_dt, conMedEndDT = seed_dt, conMedDays = 1L))
    }
    
    eligible <- union(seed_med, get_new_any(seed_dt))
    current  <- seed_dt
    
    repeat {
      d1 <- current + 1
      if (d1 > last_date) break
      
      present_d1 <- intersect(get_meds(d1), union(eligible, get_new_any(d1)))
      if (length(present_d1) > 0) {
        eligible <- union(eligible, get_new_any(d1))
        current  <- d1
        next
      }
      
      d2 <- current + 2
      if (d2 > last_date) break
      present_t  <- intersect(get_meds(current), eligible)
      present_d2 <- intersect(get_meds(d2),     eligible)
      if (length(intersect(present_t, present_d2)) > 0) {
        eligible <- union(eligible, get_new_any(d2))
        current  <- d2
        next
      }
      
      break
    }
    
    tibble::tibble(
      conMedStartDT = seed_dt,
      conMedEndDT   = current,
      conMedDays    = as.integer(current - seed_dt) + 1L
    )
  }
  
  .qad_mark("computed streaks")
  
  # 5. Expand seeds → streaks (Map is base-R and fast; allow cartesian for multi-seeds)
  meds_con_seeds_dt <- merge(qad_seeds, daily_by_pt_dt, by = c("patientID","episodeID"), all.x = TRUE, allow.cartesian = TRUE)
  meds_con_seeds_dt[, res := Map(extend_from_seed, dtbl, seed_dt, hospitalDischargeDT, med)]
  
  # unnest and attach ET end date
  meds_con_long_dt <- meds_con_seeds_dt[
    , res[[1L]],         # expand the small tibble
    by = .(patientID, episodeID, med, seed_dt)
  ]
  
  # attach conMedEndDT_ET from daily_dt
  end_lookup_dt <- daily_dt[, .(patientID, episodeID, conMedEndDT = medicationTakenDT, conMedEndDT_ET = end_ET)]
  data.table::setkey(end_lookup_dt, patientID, episodeID, conMedEndDT)
  data.table::setkey(meds_con_long_dt, patientID, episodeID, conMedEndDT)
  meds_con_long_dt <- end_lookup_dt[meds_con_long_dt]
  
  # final de-dup (should be minimal)
  meds_con_final_dt <- unique(meds_con_long_dt[, .(patientID, episodeID, conMedStartDT, conMedEndDT, conMedDays, conMedEndDT_ET)])
  
  # if you need a tibble downstream:
  meds_con_final <- tibble::as_tibble(meds_con_final_dt)
  
  # timing
  qad_total <- (proc.time() - qad_t0)[["elapsed"]]
  message(sprintf("[QAD] TOTAL %7.1f s (%.2f min)", qad_total, qad_total/60))
  
  # optional save
  if (!is.null(save_paths$conmeds)) {
    dir.create(dirname(save_paths$conmeds), recursive = TRUE, showWarnings = FALSE)
    saveRDS(meds_con_final, save_paths$conmeds)
    message("Saved meds_con_final to: ", save_paths$conmeds)
  }
  # Add med to psi datset ---------------------------------------------------
  
  psi.pop2 <- left_join(psi.pop,meds_con_final,by=c("patientID","episodeID"),relationship = "many-to-many") %>% 
    filter(conMedStartDT >= inf_anchor_dt-1 & conMedStartDT <= inf_anchor_dt+1) %>% 
    # define infection onset
    # Infection Onset Date = earliest of infection anchor date or first QAD
    # Community-Onset Infection = infection onset date < hospital day 4
    # Hospital-Onset Infection = infection onset >= hospital day 4
    mutate(
      # robust min: if both are NA -> NA; else take the earlier date
      inf_onset_dt = if_else(
        is.na(inf_anchor_dt) & is.na(conMedStartDT),
        as.Date(NA),
        pmin(inf_anchor_dt, conMedStartDT, na.rm = TRUE)
      ),
      # flag which date set the onset
      inf_onset_src = case_when(
        !is.na(conMedStartDT) & (is.na(inf_anchor_dt) | conMedStartDT < inf_anchor_dt) ~ "QAD",
        !is.na(inf_anchor_dt) ~ "BCX/DX",
        TRUE ~ NA_character_
      ),
      # calendar day of onset (startDT is day 1)
      inf_onset_day = as.numeric(inf_onset_dt - startDT)+1L,
      
      inf_type = if_else(inf_onset_day < 4L, "CO", "HO")
      )
    
  
  keep_vars <- c("patientID","episodeID","dx_ahrqinf_poa","inf_anchor_dt","inf_anchor_src",
                 "inf_onset_dt","inf_onset_src","inf_onset_day","inf_type",
                 "conMedStartDT","conMedEndDT","conMedDays")
  
  # >= 4 Qualifying Antibiotic Days starting within +/- 1 day of infection onset date
  qad <- psi.pop2 %>% 
    filter(conMedDays >= 4)
  
  qad.b <- qad %>%
    select(all_of(keep_vars))
  
  # 3 QADs are allowed for community-onset sepsis if the patient is discharged alive on the 3rd QAD 
  # and had both a blood culture drawn and infection/sepsis as a principal diagnosis
  dcalive3qad <-  psi.pop2 %>% 
    filter(inf_type=="CO" & conMedDays==3 & 
             conMedEndDT==hospitalDischargeDT & dx_ahrqinf_poa==1 & inf_anchor_src=="BCX" & 
             !toupper(dischargeDispositionGroup) %in% c("DEAD", "HOSPICE"))
  
  dcalive3qad.b <- dcalive3qad %>% 
    select(all_of(keep_vars))
    
  # Fewer than 4 antibiotic days allowed if antibiotics are given up to <=1 day before death
  dth <- psi.pop2 %>% 
    filter(!is.na(deathDT_derived)) %>% 
    mutate(diff = as.numeric(deathDT_derived - conMedEndDT)) %>% 
    filter(diff <= 1)
  
  dth.b <- dth %>% 
    select(all_of(keep_vars))
  
  # Fewer than 4 antibiotic days allowed if antibiotics are given up to <=1 day before
  # discharge to hospice or another acute care hospital
  dc <- psi.pop2 %>% 
    filter(toupper(dischargeDispositionGroup) %in% c("DEAD","HOSPICE","ACUTE CARE HOSPITAL")) %>% 
    mutate(diff = as.numeric(hospitalDischargeDT - conMedEndDT)) %>% 
    filter(diff <= 1)
  
  dc.b <- dc %>% 
    select(all_of(keep_vars))
  
  # Fewer than 4 antibiotic days allowed if antibiotics are given up to <=1 day before transition to comfort care
  cmftcare <- fread(file.path(edw_data_dir,paste0("daily_",edw_ver,".csv")), colClasses = 'character', data.table = FALSE) %>% 
    filter(comfortCare==1) %>%
    select(patientID,eventDate,comfortCare) %>% 
    mutate(cmftcare_date=ymd(eventDate)) %>% 
    distinct()
  
  cmftcare_pop <- inner_join(psi.pop2,cmftcare,by="patientID",relationship = "many-to-many") %>%
    # EDW daily dataset has a bug where eventDate was output in Eastern time zone
    mutate(cmftcare_to_conMedEnd_days = as.numeric(cmftcare_date - conMedEndDT_ET)) %>% 
    # we don't need cmftcare_to_conMedEnd_days to be < -2 bc those will get picked up by 4 QADs
    filter(conMedDays <= 3 & cmftcare_to_conMedEnd_days >= -2 & cmftcare_to_conMedEnd_days <= 1)
  
  cmftcare_pop.b <- cmftcare_pop %>% 
    select(all_of(keep_vars))
  
  # Final dataset -----------------------------------------------------------
  
  # indx_split in this dataset is for consecutive meds
  psi.pop3 <- bind_rows(qad.b,dcalive3qad.b,dth.b,dc.b,cmftcare_pop.b) %>% 
    distinct()
  
  # take max conMedDays
  psi.pop4 <- psi.pop3 %>% 
    group_by(patientID,episodeID,inf_onset_dt) %>% 
    filter(conMedDays==max(conMedDays)) %>% 
    ungroup()
  
  # ensure a single inf_onset_dt per inf_anchor_dt
  # tie-breakers: earliest inf_onset_dt, then longest conMedDays
  psi.pop4_one <- psi.pop4 %>%
    group_by(patientID, episodeID, inf_anchor_dt) %>%
    arrange(inf_onset_dt, desc(conMedDays), .by_group = TRUE) %>%
    slice(1) %>%
    ungroup()
  
  # create indx for infection onset
  psi.pop5 <- psi.pop4_one %>% 
    group_by(patientID,episodeID) %>%
    mutate(inf_indx=row_number()) %>% 
    ungroup() 
  
  # need these for organ dysfunctions
  add.vars <- ep.bcx %>% 
    select(patientID,episodeID,startDT,hospitalDischargeDT,
             starts_with("dx_"),sex,dischargeDispositionGroup,-dx_ahrqinf_poa) %>% 
    distinct()
  
  # output dataset is one row per patientID-episodeID-psi_indx
  # can have multiple psi_indx with the same psi_onsetDT
  psi_detail <- left_join(psi.pop5,add.vars,by=c("patientID","episodeID")) %>% 
    select(patientID,episodeID,startDT,hospitalDischargeDT,sex,dischargeDispositionGroup,
           inf_indx,conMedStartDT,conMedEndDT,conMedDays,inf_anchor_dt,inf_anchor_src,
           inf_onset_dt,inf_onset_src,inf_onset_day,inf_type,starts_with("dx_"))
  
  
  nrow(psi_detail)
  
  psi_detail %>% group_by(patientID,episodeID,inf_indx) %>% tally() %>% filter(n>1)
  
  glimpse(psi_detail)
  
  # optional save
  if (!is.null(save_paths$psi_detail)) {
    dir.create(dirname(save_paths$psi_detail), recursive = TRUE, showWarnings = FALSE)
    saveRDS(psi_detail, save_paths$psi_detail)
    message("Saved psi_detail to: ", save_paths$psi_detail)
  }
  
  # --- Return reduced final dataset ---
  psi_cohort <- psi_detail %>%
    select(-inf_indx, -conMedStartDT, -conMedEndDT, -conMedDays,
           -inf_anchor_dt, -inf_anchor_src, -inf_onset_src) %>%
    distinct()
  
  nrow(psi_cohort)
  nrow(distinct(psi_cohort,patientID,episodeID,inf_onset_dt))
  
  message("CDC ASE presumed serious infection dataset generation complete.")
  
  # optional save
  if (!is.null(save_paths$psi_cohort)) {
    dir.create(dirname(save_paths$psi_cohort), recursive = TRUE, showWarnings = FALSE)
    saveRDS(psi_cohort, save_paths$psi_cohort)
    message("Saved psi_cohort to: ", save_paths$psi_cohort)
  }
  
  return(psi_cohort)
  
}