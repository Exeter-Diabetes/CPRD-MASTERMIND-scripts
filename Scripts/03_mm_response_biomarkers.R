
# Extracts 6 month and 12 month response biomarkers
## 6 month response: must be at least 3 months from drug start date, before another drug class added/removed, and no later than drug stop date + 91 days
## 12 month response: must be at least 9 months from drug start date, before another drug class added/removed, and no later than drug stop date + 91 days

# (Unlike for baseline biomarkers): only want for first instances of drug class (i.e. not where patient has taken drug, stopped, and then restarted)
# HbA1c only: response missing where timeprevcombo<=61 days before drug initiation

# All biomarker tests merged with all drug start and stop dates (plus timetochange, timeaddrem and multi_drug_start from mm_combo_start_stop = combination start stop table) in script 2_mm_baseline_biomarkers - tables created have names of the form 'mm_full_{biomarker}_drug_merge'

# Also finds date of 40% decline in eGFR outcome (if present)


############################################################################################

# Setup
library(tidyverse)
library(aurum)
rm(list=ls())

cprd = CPRDData$new(cprdEnv = "test-remote",cprdConf = "~/.aurum.yaml")
#codesets = cprd$codesets()
#codes = codesets$getAllCodeSetVersion(v = "31/10/2021")

analysis = cprd$analysis("mm")


############################################################################################

# Define biomarkers (can include HbA1c as processed the same as others; don't include height)

biomarkers <- c("weight", "bmi", "fastingglucose", "hdl", "triglyceride", "creatinine_blood", "ldl", "alt", "ast", "totalcholesterol", "dbp", "sbp", "acr", "hba1c", "egfr", "albumin_blood", "bilirubin", "haematocrit", "haemoglobin", "pcr")


############################################################################################

# Pull out 6 month and 12 month biomarker values

## Loop through full biomarker drug merge tables

## Just keep first instance

## Define earliest (min) and latest (last) valid date for each response length (6m and 12m)
### Earliest = 3 months for 6m response/9 months for 12m response
### Latest = minimum of timetochange + 91 days, timetoaddrem and 9 months (for 6m response)/15 months (for 12m response)

## Then use closest date to 6/12 months post drug start date
### May be multiple values; use minimum
### Can get duplicates where person has identical results on the same day/days equidistant from 6/12 months post drug start - choose first row when ordered by drugdatediff

# Then combine with baseline values and find response
## Remove HbA1c responses where timeprevcombo<=61 days i.e. where change glucose-lowering meds less than 61 days before current drug initation


# 6 month response

for (i in biomarkers) {
  
  print(i)
  
  drug_merge_tablename <- paste0("full_", i, "_drug_merge")
  post6m_table_name <- paste0("post6m_", i)
  
  drug_merge_tablename <- drug_merge_tablename %>% analysis$cached(drug_merge_tablename)
  
  data <- drug_merge_tablename %>%
    
    filter(druginstance==1)  %>%
    
    mutate(minvaliddate6m = sql("date_add(dstartdate, interval 91 day)"),
           
           # pmin gets translated to SQL LEAST which doesn't like missing values
           maxtime6m = pmin(ifelse(is.na(timetoaddrem), 274, timetoaddrem),
                            ifelse(is.na(timetochange), 274, timetochange+91), 274, na.rm=TRUE),
           
           lastvaliddate6m=if_else(maxtime6m<91, NA, sql("date_add(dstartdate, interval maxtime6m day)"))) %>%
    
    filter(date>=minvaliddate6m & date<=lastvaliddate6m) %>%
    
    group_by(patid, dstartdate, drugclass) %>%
    
    mutate(min_timediff=min(abs(183-drugdatediff), na.rm=TRUE)) %>%
    filter(abs(183-drugdatediff)==min_timediff) %>%
    
    mutate(post_biomarker_6m=min(testvalue, na.rm=TRUE)) %>%
    filter(post_biomarker_6m==testvalue) %>%
    
    dbplyr::window_order(drugdatediff) %>%
    filter(row_number()==1) %>%
    
    ungroup() %>%
    
    select(patid, dstartdate, drugclass, post_biomarker_6m, post_biomarker_6mdate=date, post_biomarker_6mdrugdiff=drugdatediff) %>%
    
    analysis$cached(post6m_table_name, indexes=c("patid", "dstartdate", "drugclass"))
  
  assign(post6m_table_name, data)
  
}


# 12 month response

for (i in biomarkers) {
  
  print(i)
  
  drug_merge_tablename <- paste0("full_", i, "_drug_merge")
  post12m_table_name <- paste0("post12m_", i)
  
  drug_merge_tablename <- drug_merge_tablename %>% analysis$cached(drug_merge_tablename)
  
  data <- drug_merge_tablename %>%
    
    filter(druginstance==1)  %>%
    
    mutate(minvaliddate12m = sql("date_add(dstartdate, interval 274 day)"),
           
           # pmin gets translated to SQL LEAST which doesn't like missing values
           maxtime12m = pmin(ifelse(is.na(timetoaddrem), 457, timetoaddrem),
                             ifelse(is.na(timetochange), 457, timetochange+91), 457, na.rm=TRUE),
           
           lastvaliddate12m=if_else(maxtime12m<274, NA, sql("date_add(dstartdate, interval maxtime12m day)"))) %>%
    
    filter(date>=minvaliddate12m & date<=lastvaliddate12m) %>%
    
    group_by(patid, dstartdate, drugclass) %>%
    
    mutate(min_timediff=min(abs(365-drugdatediff), na.rm=TRUE)) %>%
    filter(abs(365-drugdatediff)==min_timediff) %>%
    
    mutate(post_biomarker_12m=min(testvalue, na.rm=TRUE)) %>%
    filter(post_biomarker_12m==testvalue) %>%
    
    dbplyr::window_order(drugdatediff) %>%
    filter(row_number()==1) %>%
    
    ungroup() %>%
    
    select(patid, dstartdate, drugclass, post_biomarker_12m, post_biomarker_12mdate=date, post_biomarker_12mdrugdiff=drugdatediff) %>%
    
    analysis$cached(post12m_table_name, indexes=c("patid", "dstartdate", "drugclass"))
  
  assign(post12m_table_name, data)
  
}


# Combine with baseline values and find response

baseline_biomarkers <- baseline_biomarkers %>% analysis$cached("baseline_biomarkers")
combo_start_stop <- combo_start_stop %>% analysis$cached("combo_start_stop")

response_biomarkers <- baseline_biomarkers %>%
  left_join((combo_start_stop %>% select(patid, dcstartdate, timetochange, timetoaddrem, multi_drug_start, timeprevcombo)), by=c("patid","dstartdate"="dcstartdate")) %>%
  filter(druginstance==1)


for (i in biomarkers) {
  
  print(i)
  
  post6m_table <- get(paste0("post6m_", i))
  post12m_table <- get(paste0("post12m_", i))

  pre_biomarker_variable <- as.symbol(paste0("pre", i))
  pre_biomarker_date_variable <- as.symbol(paste0("pre", i, "date"))
  pre_biomarker_drugdiff_variable <- as.symbol(paste0("pre", i, "drugdiff"))
  
  post_6m_biomarker_variable <- paste0("post", i, "6m")
  post_6m_biomarker_date_variable <- paste0("post", i, "6mdate")
  post_6m_biomarker_drugdiff_variable <- paste0("post", i, "6mdrugdiff")
  biomarker_6m_response_variable <- paste0(i, "resp6m")
  post_12m_biomarker_variable <- paste0("post", i, "12m")
  post_12m_biomarker_date_variable <- paste0("post", i, "12mdate")
  post_12m_biomarker_drugdiff_variable <- paste0("post", i, "12mdrugdiff")
  biomarker_12m_response_variable <- paste0(i, "resp12m")
  
  interim_response_biomarker_table <- paste0("response_biomarkers_interim_", i)
  
  response_biomarkers <- response_biomarkers %>%
    left_join(post6m_table, by=c("patid", "dstartdate", "drugclass")) %>%
    left_join(post12m_table, by=c("patid", "dstartdate", "drugclass"))
  
  
  if (i=="hba1c") {
    response_biomarkers <- response_biomarkers %>%
      mutate(post_biomarker_6m=ifelse(!is.na(timeprevcombo) & timeprevcombo<=61, NA, post_biomarker_6m),
             post_biomarker_6mdate=if_else(!is.na(timeprevcombo) & timeprevcombo<=61, as.Date(NA), post_biomarker_6mdate),
             post_biomarker_6mdrugdiff=ifelse(!is.na(timeprevcombo) & timeprevcombo<=61, NA, post_biomarker_6mdrugdiff),
             post_biomarker_12m=ifelse(!is.na(timeprevcombo) & timeprevcombo<=61, NA, post_biomarker_12m),
             post_biomarker_12mdate=if_else(!is.na(timeprevcombo) & timeprevcombo<=61, as.Date(NA), post_biomarker_12mdate),
             post_biomarker_12mdrugdiff=ifelse(!is.na(timeprevcombo) & timeprevcombo<=61, NA, post_biomarker_12mdrugdiff))
  }
   
   
  response_biomarkers <- response_biomarkers %>%
    relocate(pre_biomarker_variable, .before=post_biomarker_6m) %>%
    relocate(pre_biomarker_date_variable, .before=post_biomarker_6m) %>%
    relocate(pre_biomarker_drugdiff_variable, .before=post_biomarker_6m) %>%
    
    mutate({{biomarker_6m_response_variable}}:=ifelse(!is.na(pre_biomarker_variable) & !is.na(post_biomarker_6m), post_biomarker_6m-pre_biomarker_variable, NA),
           {{biomarker_12m_response_variable}}:=ifelse(!is.na(pre_biomarker_variable) & !is.na(post_biomarker_12m), post_biomarker_12m-pre_biomarker_variable, NA)) %>%
    
    rename({{post_6m_biomarker_variable}}:=post_biomarker_6m,
           {{post_6m_biomarker_date_variable}}:=post_biomarker_6mdate,
           {{post_6m_biomarker_drugdiff_variable}}:=post_biomarker_6mdrugdiff,
           {{post_12m_biomarker_variable}}:=post_biomarker_12m,
           {{post_12m_biomarker_date_variable}}:=post_biomarker_12mdate,
           {{post_12m_biomarker_drugdiff_variable}}:=post_biomarker_12mdrugdiff) %>%
    
    analysis$cached(interim_response_biomarker_table, indexes=c("patid", "dstartdate", "drugclass"))
  
}


# Add in 40% decline in eGFR outcome

analysis = cprd$analysis("all")

egfr_long <- egfr_long %>% analysis$cached("patid_clean_egfr_medcodes")

analysis = cprd$analysis("mm")

## Join drug start dates with all longitudinal eGFR measurements, and only keep later eGFR measurements which are <=40% of the baseline value
## And at least 7 days after drug start, as baseline measurements go up to 7 days post drug initiation
## Checked and those with null eGFR do get dropped
egfr40 <- baseline_biomarkers %>%
  select(patid, drugclass, dstartdate, preegfr) %>%
  left_join(egfr_long, by="patid") %>%
  filter(datediff(date, dstartdate)>7 & testvalue<=0.4*preegfr) %>%
  analysis$cached("response_biomarkers_egfr40_1", indexes=c("patid", "dstartdate", "drugclass"))

## Find the earliest date for each drug start
egfr40 <- egfr40 %>%
  group_by(patid, drugclass, dstartdate) %>%
  summarise(egfr_40_decline_date=min(date, na.rm=TRUE)) %>%
  analysis$cached("response_biomarkers_egfr40_2", indexes=c("patid", "dstartdate", "drugclass"))

## Join to rest of response dataset and move where height variable is
response_biomarkers <- response_biomarkers %>%
  left_join(egfr40, by=c("patid", "drugclass", "dstartdate")) %>%
  relocate(height, .after=timeprevcombo) %>%
  analysis$cached("response_biomarkers", indexes=c("patid", "dstartdate", "drugclass"))
