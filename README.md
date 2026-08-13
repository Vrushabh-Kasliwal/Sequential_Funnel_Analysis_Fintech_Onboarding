# Sequential_Funnel_Analysis_Fintech_Onboarding
# Fintech Onboarding Funnel Analysis: Sequential Funnels, SQL, and Metric Design

A case study in diagnosing where users drop out of a mobile investment app's signup flow, and why "distinct users per stage" is the wrong way to measure a funnel.

## The problem

A fintech app's investment ("Save") onboarding flow moves a user through 10 stages, from app open to their first unit of investment being credited. The raw data showed a funnel snapshot with independently-counted stage totals. That snapshot pointed to one stage as the biggest leak.

The catch: independent per-stage counts don't prove *order*. A user can appear in a later-stage count without ever having passed through the earlier stage in the right sequence, especially with retries, duplicate events, and asynchronous, webhook-confirmed steps (KYC, bank linking, mandate authorization, settlement). Treating the naive snapshot as ground truth risks pointing the product team at the wrong problem.

This project walks through fixing that: designing the event schema properly, writing SQL that enforces true sequential progression, and turning the result into a testable hypothesis and a north star metric.

## What's in here

- `funnel_analysis.sql` — Recursive CTE that walks each user through the 10 stages in strict chronological order (a user only counts at stage N if their stage-N event happened *after* their validated stage-(N-1) event). Also computes step-over-step conversion, median completion time in seconds, and the largest adjacent-stage drop-off, all off the sequential (not naive) counts.
- `writeup.md` — Event specification (12-event cap, why each event fires on a confirmed state not a tap), the falsifiable hypothesis for the biggest drop-off, the north star / counter-metric pairing, and the assumptions and data-quality checks I'd run before trusting any of it.

## Key technical decisions (and why they matter)

**Recursive CTE over independent per-stage counts.** The obvious approach — `COUNT(DISTINCT user_id)` per event, independently — silently assumes order. It doesn't check that a user's `bank_verified` event actually came after their `pan_verified` event. The recursive CTE fixes this by only advancing a user to stage N+1 if their stage-(N+1) timestamp is strictly later than their already-validated stage-N timestamp. This changes the funnel shape versus the naive snapshot, and it's the difference between diagnosing the real leak and chasing a phantom one.

**Dedup to first-touch per user per event.** Retries and edits (one dataset had 14,000+ rows from ~2,300 users at a single stage) mean rows are not users. Every stage count is deduplicated to the first timestamp per user per event before the sequential walk runs.

**Completion time in seconds, not days.** A median measured in whole days hides most of the signal in a flow where the difference between a healthy and a broken cohort is minutes-to-hours (webhook latency, OTP retries). `EXTRACT(EPOCH ...)` with no downstream rounding.

**Async events fire on confirmed state, not user action.** KYC, bank verification, mandate authorization, and unit credit are all confirmed by a provider webhook or reconciliation job, not by the user tapping "continue" or returning to the app. The event spec stores `initiated_at` and `confirmed_at` separately and treats pending/failed as distinct operational states, so a slow settlement window doesn't get misread as a broken funnel.

**12-event cap forced trade-offs.** Screens like nominee selection, UPI app handoff, and intermediate SIP setup steps were cut as top-level events and demoted to properties or logs. Documenting *why* something was cut is as important as documenting what was kept.

## Approach summary

1. **Falsifiable hypothesis**, not a vague observation — stated with the exact condition that would prove it wrong (a larger drop appears once retries and delayed callbacks are accounted for).
2. **North star + counter-metric pair** — weekly users reaching first unit credit within 30 days of app open, paired with 30-day early cancellation/failure rate among credited users, so growth can't be optimized by shipping something that increases signups but tanks retention.
3. **Pre-registered data-quality checks** — duplicate event IDs, clock skew, event-name drift, identity stitching across sessions/devices, multi-order users, incomplete maturity windows. Listed before results are trusted, not after something looks wrong.

## Skills demonstrated

`SQL (recursive CTEs, window functions, percentile_cont)` · `event taxonomy / instrumentation design` · `funnel analysis` · `hypothesis-driven metric design` · `data quality auditing`

---

*Note: underlying data and company identity are not included; this repo demonstrates the analytical and SQL approach only.*
