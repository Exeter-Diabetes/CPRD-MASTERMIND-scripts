
# Extract dataset of all first instance drug periods (i.e. the first time patient has taken this particular drug class) for T2Ds WITH HES LINKAGE
## Set diabetes diagnosis date (dm_diag_date) and diabetes diagnosis age (dm_diag_age) to missing where diagnosed in the 91 days following registration (i.e. where dm_diag_flag==1)
## Exclude drug periods starting within 91 days of registration
## Set drugline to missing where diagnosed before registration

## Do not exclude where first line
## Do not exclude where patient is on insulin at drug initiation
## Do not exclude where only 1 prescription (dstartdate=dstopdate)

## Set hosp_admission_prev_year to 0/1 rather than NA/1

# Also extract all T2D drug start and stop dates for T2Ds so that you can see if people later initiate SGLT2is/GLP1s etc.

############################################################################################

# Setup
library(tidyverse)
library(aurum)
library(EHRBiomarkr)
rm(list=ls())

cprd = CPRDData$new(cprdEnv = "test-remote",cprdConf = "~/.aurum.yaml")

analysis = cprd$analysis("mm")


############################################################################################

# Get handles to pre-existing data tables

## Cohort and patient characteristics
analysis = cprd$analysis("all")
t1t2_cohort <- t1t2_cohort %>% analysis$cached("t1t2_cohort")
analysis = cprd$analysis("mm")

## Drug info
drug_start_stop <- drug_start_stop %>% analysis$cached("drug_start_stop")
combo_start_stop <- combo_start_stop %>% analysis$cached("combo_start_stop")

## Biomarkers inc. CKD
#baseline_biomarkers <- baseline_biomarkers %>% analysis$cached("baseline_biomarkers")
response_biomarkers <- response_biomarkers %>% analysis$cached("response_biomarkers") #includes baseline biomarker values for first instance drug periods so no need to use baseline_biomakers table
ckd_stages <- ckd_stages %>% analysis$cached("ckd_stages")

## Comorbidities
comorbidities <- comorbidities %>% analysis$cached("comorbidities")

## Non-diabetes meds
non_diabetes_meds <- non_diabetes_meds %>% analysis$cached("non_diabetes_meds")

## Smoking status at drug start
smoking <- smoking %>% analysis$cached("smoking")

## Discontinuation
discontinuation <- discontinuation %>% analysis$cached("discontinuation")

## Death causes
death_causes <- death_causes %>% analysis$cached("death_causes")


############################################################################################

# Make first instance drug period dataset

## Define T2D cohort (1 line per patient) with HES linkage
## Make new variables for diabetes diagnosis date and age which are missing if diagnosed with diabetes within 91 days following registration (dm_diag_flag==1)
t2ds <- t1t2_cohort %>%
  filter(diabetes_type=="type 2" & with_hes==1) %>%
  mutate(dm_diag_date=ifelse(dm_diag_flag==1, as.Date(NA), dm_diag_date_all),
         dm_diag_age=ifelse(dm_diag_flag==1, NA, dm_diag_age_all))


## Get info for first instance drug periods for cohort (1 line per patid-drugclass period)
### Make new drugline variable which is missing where diagnosed before registration

t2d_drug_periods <- t2ds %>%
  inner_join(drug_start_stop, by="patid") %>%
  inner_join(combo_start_stop, by=c("patid", c("dstartdate"="dcstartdate"))) %>%
  mutate(drugline=ifelse(dm_diag_date_all<regstartdate, NA, drugline_all))

t2d_drug_periods %>% distinct(patid) %>% count()
# 865,124
  

### Keep first instance only
t2d_1stinstance <- t2d_drug_periods %>%
  filter(druginstance==1)

t2d_1stinstance %>% distinct(patid) %>% count()
# 865,124 as above


### Exclude drug periods starting within 91 days of registration
t2d_1stinstance <- t2d_1stinstance %>%
  filter(datediff(dstartdate, regstartdate)>91)

t2d_1stinstance %>% count()
# 1,662,380

t2d_1stinstance %>% distinct(patid) %>% count()
# 769,197



## Merge in biomarkers, comorbidities, non-diabetes meds, smoking status
### Could merge on druginstance too, but quicker not to
### Remove some variables to avoid duplicates
### Make new variables: age at drug start, diabetes duration at drug start, CV risk scores

t2d_1stinstance <- t2d_1stinstance %>%
  inner_join((response_biomarkers %>% select(-c(druginstance, timetochange, timetoaddrem, multi_drug_start, timeprevcombo))), by=c("patid", "dstartdate", "drugclass")) %>%
  inner_join((ckd_stages %>% select(-druginstance)), by=c("patid", "dstartdate", "drugclass")) %>%
  inner_join((comorbidities %>% select(-druginstance)), by=c("patid", "dstartdate", "drugclass")) %>%
  inner_join((non_diabetes_meds %>% select(-druginstance)), by=c("patid", "dstartdate", "drugclass")) %>%
  inner_join((smoking %>% select(-druginstance)), by=c("patid", "dstartdate", "drugclass")) %>%
  inner_join((discontinuation %>% select(-c(druginstance, timeondrug, nextremdrug, timetolastpx))), by=c("patid", "dstartdate", "drugclass")) %>%
  left_join(death_causes, by="patid") %>%
  mutate(dstartdate_age=datediff(dstartdate, dob)/365.25,
         dstartdate_dm_dur_all=datediff(dstartdate, dm_diag_date_all)/365.25,
         dstartdate_dm_dur=datediff(dstartdate, dm_diag_date)/365.25,
         hosp_admission_prev_year=ifelse(is.na(hosp_admission_prev_year) & with_hes==1, 0L,
                                         ifelse(hosp_admission_prev_year==1, 1L, NA))) %>%
  analysis$cached("20230116_t2d_1stinstance_interim_1", indexes=c("patid", "dstartdate", "drugclass"))


# Check counts

t2d_1stinstance %>% count()
# 1,662,380

t2d_1stinstance %>% distinct(patid) %>% count()
# 769,197


############################################################################################

# Add in 5 year QDiabetes-HF score and QRISK2 score

## Make separate table with additional variables for QRISK2 and QDiabetes-HF

qscore_vars <- t2d_1stinstance %>%
  mutate(precholhdl=pretotalcholesterol/prehdl,
         ckd45=preckdstage=="stage_4" | preckdstage=="stage_5",
         cvd=predrug_myocardialinfarction==1 | predrug_angina==1 | predrug_stroke==1,
         sex=ifelse(gender==1, "male", ifelse(gender==2, "female", "NA")),
         dm_duration_cat=ifelse(dstartdate_dm_dur_all<=1, 0L,
                                ifelse(dstartdate_dm_dur_all<4, 1L,
                                       ifelse(dstartdate_dm_dur_all<7, 2L,
                                              ifelse(dstartdate_dm_dur_all<11, 3L, 4L)))),
         
         earliest_bp_med=pmin(
           ifelse(is.na(predrug_earliest_ace_inhibitors),as.Date("2050-01-01"),predrug_earliest_ace_inhibitors),
           ifelse(is.na(predrug_earliest_beta_blockers),as.Date("2050-01-01"),predrug_earliest_beta_blockers),
           ifelse(is.na(predrug_earliest_calcium_channel_blockers),as.Date("2050-01-01"),predrug_earliest_calcium_channel_blockers),
           ifelse(is.na(predrug_earliest_thiazide_diuretics),as.Date("2050-01-01"),predrug_earliest_thiazide_diuretics),
           na.rm=TRUE
         ),
         latest_bp_med=pmax(
           ifelse(is.na(predrug_latest_ace_inhibitors),as.Date("1900-01-01"),predrug_latest_ace_inhibitors),
           ifelse(is.na(predrug_latest_beta_blockers),as.Date("1900-01-01"),predrug_latest_beta_blockers),
           ifelse(is.na(predrug_latest_calcium_channel_blockers),as.Date("1900-01-01"),predrug_latest_calcium_channel_blockers),
           ifelse(is.na(predrug_latest_thiazide_diuretics),as.Date("1900-01-01"),predrug_latest_thiazide_diuretics),
           na.rm=TRUE
         ),
         bp_meds=ifelse(earliest_bp_med!=as.Date("2050-01-01") & latest_bp_med!=as.Date("1900-01-01") & datediff(latest_bp_med, dstartdate)<=28 & earliest_bp_med!=latest_bp_med, 1L, 0L),
         
         type1=0L,
         type2=1L,
         surv_5yr=5L,
         surv_10yr=10L) %>%
  
  select(patid, dstartdate, drugclass, sex, dstartdate_age, ethnicity_qrisk2, qrisk2_smoking_cat, dm_duration_cat, bp_meds, type1, type2, cvd, ckd45, predrug_fh_premature_cvd, predrug_af, predrug_rheumatoidarthritis, prehba1c, precholhdl, presbp, prebmi, tds_2011, surv_5yr, surv_10yr) %>%
  
  analysis$cached("20230116_t2d_1stinstance_interim_2", indexes=c("patid", "dstartdate", "drugclass"))



## Calculate 5 year QDiabetes-HF and 5 year and 10 year QRISK2 scores
### For some reason it doesn't like collation of sex variable unless remake it

## Remove QDiabetes-HF score for those with biomarker values outside of range:
### CholHDL: missing or 1-11 (NOT 12)
### HbA1c: 40-150
### SBP: missing or 70-210
### Age: 25-84
### Also exclude if BMI<20 as v. different from development cohort

## Remove QRISK2 score for those with biomarker values outside of range:
### CholHDL: missing or 1-12
### SBP: missing or 70-210
### Age: 25-84
### Also exclude if BMI<20 as v. different from development cohort

qscores <- qscore_vars %>%
  
  mutate(sex2=ifelse(sex=="male", "male", ifelse(sex=="female", "female", NA))) %>%
  
  calculate_qdiabeteshf(sex=sex2, age=dstartdate_age, ethrisk=ethnicity_qrisk2, smoking=qrisk2_smoking_cat, duration=dm_duration_cat, type1=type1, cvd=cvd, renal=ckd45, af=predrug_af, hba1c=prehba1c, cholhdl=precholhdl, sbp=presbp, bmi=prebmi, town=tds_2011, surv=surv_5yr) %>%

  analysis$cached("20230116_t2d_1stinstance_interim_3", indexes=c("patid", "dstartdate", "drugclass"))
  
  

qscores <- qscores %>%
  
  mutate(sex2=ifelse(sex=="male", "male", ifelse(sex=="female", "female", NA))) %>%
  
  calculate_qrisk2(sex=sex2, age=dstartdate_age, ethrisk=ethnicity_qrisk2, smoking=qrisk2_smoking_cat, type1=type1, type2=type2, fh_cvd=predrug_fh_premature_cvd, renal=ckd45, af=predrug_af, rheumatoid_arth=predrug_rheumatoidarthritis, cholhdl=precholhdl, sbp=presbp, bmi=prebmi, bp_med=bp_meds, town=tds_2011, surv=surv_5yr) %>%
  
  rename(qrisk2_score_5yr=qrisk2_score) %>%
  
  select(-qrisk2_lin_predictor) %>%
  
  analysis$cached("20230116_t2d_1stinstance_interim_4", indexes=c("patid", "dstartdate", "drugclass"))
  


qscores <- qscores %>%
  
  mutate(sex2=ifelse(sex=="male", "male", ifelse(sex=="female", "female", NA))) %>%
  
  calculate_qrisk2(sex=sex2, age=dstartdate_age, ethrisk=ethnicity_qrisk2, smoking=qrisk2_smoking_cat, type1=type1, type2=type2, fh_cvd=predrug_fh_premature_cvd, renal=ckd45, af=predrug_af, rheumatoid_arth=predrug_rheumatoidarthritis, cholhdl=precholhdl, sbp=presbp, bmi=prebmi, bp_med=bp_meds, town=tds_2011, surv=surv_10yr) %>%

  
  mutate(qdiabeteshf_5yr_score=ifelse((is.na(precholhdl) | (precholhdl>=1 & precholhdl<=11)) &
                                        prehba1c>=40 & prehba1c<=150 &
                                        (is.na(presbp) | (presbp>=70 & presbp<=210)) &
                                        dstartdate_age>=25 & dstartdate_age<=84 &
                                        prebmi>=20, qdiabeteshf_score, NA),
         
         qdiabeteshf_lin_predictor=ifelse((is.na(precholhdl) | (precholhdl>=1 & precholhdl<=11)) &
                                                prehba1c>=40 & prehba1c<=150 &
                                                (is.na(presbp) | (presbp>=70 & presbp<=210)) &
                                                dstartdate_age>=25 & dstartdate_age<=84 &
                                                prebmi>=20, qdiabeteshf_lin_predictor, NA),
         
         qrisk2_5yr_score=ifelse((is.na(precholhdl) | (precholhdl>=1 & precholhdl<=12)) &
                                    (is.na(presbp) | (presbp>=70 & presbp<=210)) &
                                    dstartdate_age>=25 & dstartdate_age<=84 &
                                    prebmi>=20, qrisk2_score_5yr, NA),
         
         qrisk2_10yr_score=ifelse((is.na(precholhdl) | (precholhdl>=1 & precholhdl<=12)) &
                                   (is.na(presbp) | (presbp>=70 & presbp<=210)) &
                                   dstartdate_age>=25 & dstartdate_age<=84 &
                                   prebmi>=20, qrisk2_score, NA),
         
         qrisk2_lin_predictor=ifelse((is.na(precholhdl) | (precholhdl>=1 & precholhdl<=12)) &
                                            (is.na(presbp) | (presbp>=70 & presbp<=210)) &
                                            dstartdate_age>=25 & dstartdate_age<=84 &
                                            prebmi>=20, qrisk2_lin_predictor, NA)) %>%
  
  select(patid, dstartdate, drugclass, qdiabeteshf_5yr_score, qdiabeteshf_lin_predictor, qrisk2_5yr_score, qrisk2_10yr_score, qrisk2_lin_predictor) %>%
  
  analysis$cached("20230116_t2d_1stinstance_interim_5", indexes=c("patid", "dstartdate", "drugclass"))

  

## Join with main dataset

t2d_1stinstance <- t2d_1stinstance %>%
  left_join(qscores, by=c("patid", "dstartdate", "drugclass")) %>%
  analysis$cached("20230116_t2d_1stinstance", indexes=c("patid", "dstartdate", "drugclass"))


############################################################################################

# Export to R data object
## Convert integer64 datatypes to double

t2d_1stinstance_a <- collect(t2d_1stinstance %>% filter(patid<2000000000000) %>% mutate(patid=as.character(patid)))

is.integer64 <- function(x){
  class(x)=="integer64"
}

t2d_1stinstance_a <- t2d_1stinstance_a %>%
  mutate_if(is.integer64, as.integer)

save(t2d_1stinstance_a, file="20230116_t2d_1stinstance_a.Rda")

rm(t2d_1stinstance_a)


t2d_1stinstance_b <- collect(t2d_1stinstance %>% filter(patid>=2000000000000) %>% mutate(patid=as.character(patid)))

t2d_1stinstance_b <- t2d_1stinstance_b %>%
  mutate_if(is.integer64, as.integer)

save(t2d_1stinstance_b, file="20230116_t2d_1stinstance_b.Rda")

rm(t2d_1stinstance_b)


############################################################################################

# Make dataset of all T2D drug starts so that can see whether people later initiate SGLT2i/GLP1 etc.
## Set drugline to missing where diagnosed before registration

t2d_all_drug_periods <- t2ds %>%
  inner_join(drug_start_stop, by="patid") %>%
  select(patid, drugclass, dstartdate, dstopdate) %>%
  analysis$cached("20230116_t2d_all_drug_periods")


## Export to R data object
### No integer64 datatypes

t2d_all_drug_periods <- collect(t2d_all_drug_periods %>% mutate(patid=as.character(patid)))

save(t2d_all_drug_periods, file="20230116_t2d_all_drug_periods.Rda")

