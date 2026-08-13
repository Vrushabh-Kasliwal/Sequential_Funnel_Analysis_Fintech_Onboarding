-- Fintech Onboarding Funnel Analysis — Sequential Funnel SQL
--
-- Design notes:
--   1) Added a RECURSIVE CTE that enforces true sequential order: a user only
--      reaches stage N if their stage-N event happened strictly after their
--      already-validated stage-(N-1) event. The old version counted users per
--      stage independently, with no order check.
--   2) Median completion time is now in SECONDS (EXTRACT(EPOCH...) with no
--      /86400 division). The old version returned days.
--   3) "Completed" now means all 10 stages were reached in order (stage_order
--      = 10 in the recursive walk). The old version only required an
--      app_open row and a first_unit_credited row for the same user, with no
--      check that the other 8 stages ever happened.
--
-- Assumptions (unchanged from the report):
-- 1) event_name values are exactly:
--    app_open, mobile_verified, pan_verified, sip_amount_selected, bank_verified,
--    mandate_completed, additional_details_saved, investment_consent_verified,
--    sip_created, first_unit_credited
-- 2) mandate_completed and first_unit_credited are system-confirmed events.
-- 3) The funnel stages below use the same order as the onboarding funnel.
-- 4) If a user has multiple occurrences of a stage, we use the first timestamp per user per stage.
-- 5) Conversion for a stage is defined as users reaching the stage (in order) divided by
--    users reaching the prior stage (in order).
-- 6) Median completion time is measured in seconds, from first app_open to first_unit_credited,
--    for users who completed all 10 stages in order.
-- 7) Largest drop-off is measured by absolute users lost between adjacent funnel stages.

WITH RECURSIVE stage_map AS (
    SELECT * FROM (VALUES
        (1, 'app_open', 'App opened'),
        (2, 'mobile_verified', 'Mobile verified'),
        (3, 'pan_verified', 'Identity check passed'),
        (4, 'sip_amount_selected', 'Investment amount chosen'),
        (5, 'bank_verified', 'Bank account verified'),
        (6, 'mandate_completed', 'Autopay mandate authorised'),
        (7, 'additional_details_saved', 'Profile details saved'),
        (8, 'investment_consent_verified', 'Investment consent confirmed'),
        (9, 'sip_created', 'Recurring investment created'),
        (10, 'first_unit_credited', 'First units credited')
    ) AS t(stage_order, event_name, stage_name)
),

-- Step 1: dedupe to the first timestamp per user per event (assumption 4).
first_events AS (
    SELECT
        e.user_id,
        e.event_name,
        MIN(e.event_ts) AS first_event_ts
    FROM events e
    JOIN stage_map s
      ON e.event_name = s.event_name
    GROUP BY e.user_id, e.event_name
),

-- Step 2: recursively walk each user through the funnel, requiring each
-- stage's event to occur strictly after the previous validated stage's
-- event. This is what actually enforces "sequential funnel" and is what
-- the report describes as the recursive CTE.
sequential_progress AS (
    -- Base case: stage 1 (app_open) for every user who has it.
    SELECT
        fe.user_id,
        sm.stage_order,
        sm.stage_name,
        sm.event_name,
        fe.first_event_ts AS stage_ts
    FROM first_events fe
    JOIN stage_map sm
      ON sm.event_name = fe.event_name
     AND sm.stage_order = 1

    UNION ALL

    -- Recursive step: advance to stage N+1 only if that user's stage-(N+1)
    -- event timestamp is strictly after their validated stage-N timestamp.
    SELECT
        sp.user_id,
        sm_next.stage_order,
        sm_next.stage_name,
        sm_next.event_name,
        fe_next.first_event_ts AS stage_ts
    FROM sequential_progress sp
    JOIN stage_map sm_next
      ON sm_next.stage_order = sp.stage_order + 1
    JOIN first_events fe_next
      ON fe_next.user_id = sp.user_id
     AND fe_next.event_name = sm_next.event_name
     AND fe_next.first_event_ts > sp.stage_ts
),

-- Step 3: count distinct users who sequentially reached each stage.
funnel AS (
    SELECT
        s.stage_order,
        s.stage_name,
        s.event_name,
        COUNT(DISTINCT sp.user_id) AS users_reached
    FROM stage_map s
    LEFT JOIN sequential_progress sp
      ON sp.stage_order = s.stage_order
    GROUP BY s.stage_order, s.stage_name, s.event_name
),

funnel_with_conv AS (
    SELECT
        stage_order,
        stage_name,
        event_name,
        users_reached,
        ROUND(
            users_reached::numeric
            / NULLIF(LAG(users_reached) OVER (ORDER BY stage_order), 0),
            4
        ) AS step_over_step_conversion
    FROM funnel
),

-- Step 4: "completed" now means the user reached stage 10 through the
-- sequential walk, i.e. all 10 stages were observed in order.
completers AS (
    SELECT
        user_id,
        stage_ts AS first_credit_ts
    FROM sequential_progress
    WHERE stage_order = 10
),
user_times AS (
    SELECT
        c.user_id,
        open_stage.stage_ts AS first_open_ts,
        c.first_credit_ts,
        EXTRACT(EPOCH FROM (c.first_credit_ts - open_stage.stage_ts)) AS seconds_to_completion
    FROM completers c
    JOIN sequential_progress open_stage
      ON open_stage.user_id = c.user_id
     AND open_stage.stage_order = 1
),
completion_median AS (
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY seconds_to_completion) AS median_seconds_first_to_last
    FROM user_times
),

-- Step 5: largest adjacent-stage loss, now based on sequential counts.
dropoffs AS (
    SELECT
        stage_order,
        stage_name AS from_stage,
        LEAD(stage_name) OVER (ORDER BY stage_order) AS to_stage,
        users_reached - LEAD(users_reached) OVER (ORDER BY stage_order) AS users_lost
    FROM funnel
),
largest_dropoff AS (
    SELECT
        from_stage,
        to_stage,
        users_lost
    FROM dropoffs
    WHERE to_stage IS NOT NULL
    ORDER BY users_lost DESC NULLS LAST,
             stage_order
    LIMIT 1
)

SELECT
    '1_funnel' AS section,
    stage_order,
    stage_name,
    event_name,
    users_reached,
    step_over_step_conversion,
    NULL::text AS metric_name,
    NULL::numeric AS metric_value,
    NULL::text AS dropoff_from_stage,
    NULL::text AS dropoff_to_stage,
    NULL::integer AS dropoff_users_lost
FROM funnel_with_conv

UNION ALL

SELECT
    '2_median_completion_time' AS section,
    NULL::integer AS stage_order,
    NULL::text AS stage_name,
    NULL::text AS event_name,
    NULL::bigint AS users_reached,
    NULL::numeric AS step_over_step_conversion,
    'median_seconds_first_to_last' AS metric_name,
    median_seconds_first_to_last AS metric_value,
    NULL::text AS dropoff_from_stage,
    NULL::text AS dropoff_to_stage,
    NULL::integer AS dropoff_users_lost
FROM completion_median

UNION ALL

SELECT
    '3_largest_dropoff' AS section,
    NULL::integer AS stage_order,
    NULL::text AS stage_name,
    NULL::text AS event_name,
    NULL::bigint AS users_reached,
    NULL::numeric AS step_over_step_conversion,
    NULL::text AS metric_name,
    NULL::numeric AS metric_value,
    from_stage AS dropoff_from_stage,
    to_stage AS dropoff_to_stage,
    users_lost AS dropoff_users_lost
FROM largest_dropoff
ORDER BY section, stage_order NULLS LAST;

-- Separate outputs, if preferred by the reviewer:
-- 1) Funnel:
--    SELECT * FROM funnel_with_conv ORDER BY stage_order;
-- 2) Median completion time (seconds):
--    SELECT * FROM completion_median;
-- 3) Largest drop-off:
--    SELECT * FROM largest_dropoff;
