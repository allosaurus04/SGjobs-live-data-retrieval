DROP TABLE IF EXISTS staging_jobs;
CREATE TABLE staging_jobs AS
WITH cleaned AS (
    SELECT
        "jobId"
        AS job_id,
        NULLIF(trim("jobTitle"), '')
        AS job_title,
        NULLIF(trim(agency), '')
        AS agency,
        NULLIF(trim("agencyDescription"), '')
        AS agency_description,
        NULLIF(trim(platform), '')
        AS platform,
        to_timestamp("startDate"::bigint / 1000)
        AS start_date,

        CASE
            WHEN "closingDate" ~ '^\d+$' THEN
                CASE
                    WHEN to_timestamp("closingDate"::bigint / 1000)
                         >= '9999-01-01'::timestamp THEN NULL
                    ELSE to_timestamp("closingDate"::bigint / 1000)
                END
        END  
        --no then so defaults to null                                             
        AS closing_date,
        NULLIF(trim("employmentType"), '')               
        AS employment_type,
        NULLIF(trim(field), '')                          
        AS field,
        NULLIF(trim("functionalArea"), '')               
        AS functional_area,
        NULLIF(trim(industry), '')                       
        AS industry,
        NULLIF(trim(category), '')                       
        AS category,
        NULLIF(trim("educationCode"), '')                
        AS education_code,
        NULLIF("experienceYearsMin", '')::int            
        AS exp_years_min,
        NULLIF("experienceYearsMax", '')::int            
        AS exp_years_max,
        ("isNew" = 'true')                               
        AS is_new,
        NULLIF(trim("jobDescription"), '')               
        AS job_description,
        NULLIF(trim("jobResponsibilities"), '')          
        AS job_responsibilities,
        NULLIF(trim("jobRequirements"), '')              
        AS job_requirements
    FROM jobs_raw
    WHERE "jobId" IS NOT NULL AND trim("jobId") <> ''
)
-- DROPPED on purpose:
        --   location (88.7% empty), remainingDays/closingDateText (derivable),
        --   workArrangement (zero-variance: all "Full Time", no analytic value),
        --   postingNo, agencyId, *Code columns (redundant with text cols),
        --   experienceRequired (audited against min/max, then dropped)

-- Dedup: jobId has duplicates. Keep most recent.
SELECT DISTINCT ON (job_id) *
FROM cleaned
ORDER BY job_id, start_date DESC NULLS LAST;

-- Upsert staging 
INSERT INTO jobs (
    job_id, job_title, agency, agency_description, platform, start_date, closing_date,
    employment_type, field, functional_area, industry, category, education_code,
    exp_years_min, exp_years_max, is_new, job_description, job_responsibilities, job_requirements, first_seen, last_seen
)
SELECT
    job_id, job_title, agency, agency_description, platform, start_date, closing_date,
    employment_type, field, functional_area, industry, category, education_code,
    exp_years_min, exp_years_max, is_new, job_description, job_responsibilities, job_requirements, now(), now()

FROM staging_jobs
ON CONFLICT (job_id) DO UPDATE SET --insert same as existing job_id
job_title = EXCLUDED.job_title, 
closing_date = EXCLUDED.closing_date, 
is_new = EXCLUDED.is_new,
--refresh other mutable fields 
last_seen = EXCLUDED.last_seen, 
removed_at = NULL; --job comes back (rare but yk) make it alive again 
--row you tried to insert, but cos conflicting you overwrite/update instead

--disappearance detection
UPDATE jobs
SET removed_at = last_seen
WHERE removed_at IS NULL 
  AND job_id NOT IN (SELECT job_id FROM staging_jobs);

SELECT
    (SELECT count(*) FROM jobs_raw)     AS raw_rows,
    (SELECT count(*) FROM staging_jobs) AS staged_rows,
    (SELECT count(*) FROM jobs)         AS jobs_rows;
