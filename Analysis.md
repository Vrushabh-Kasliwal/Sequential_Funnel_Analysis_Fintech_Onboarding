# Full Write-up

## Executive summary

The onboarding funnel is measured as a sequential path from app open to first successful unit credit. The naive, independently-counted snapshot showed the largest apparent loss between "investment amount chosen" and "bank account verified": 2,290 vs 1,098 distinct users, roughly 48% conversion. This is treated as directional only until event order, duplicate rows, identity stitching, and asynchronous observation windows are validated — which is exactly what the sequential SQL in this repo does.

Recommendation: 10 outcome events, with externally-confirmed steps (KYC, bank link, mandate, unit credit) kept separate from user-initiated actions. North star: first unit credited within 30 days of app open. Counter-metric: early SIP failure/cancellation rate.

## Part A — Event specification

Naming convention: lowercase snake_case; outcome events fire only after their success condition is met, not on a button tap. Common fields on every event: `user_id`, `event_id`, `event_ts`, `app_version`, `platform`, `session_id`. No PAN, bank account numbers, OTPs, or UPI PINs are ever logged.

| Event | Fires on | Key properties | What a drop here means |
|---|---|---|---|
| `app_open` | App becomes active post-splash | `platform`, `app_version`, `acquisition_source`, `session_id` | Acquisition or launch-reliability problem |
| `mobile_verified` | Successful OTP verification response | `attempt_count`, `retry_count`, `entry_point` | OTP delivery or trust friction |
| `pan_verified` | Successful/confirmed identity provider response | `provider`, `status`, `failure_code`, `latency_ms` | Eligibility, provider outage, or data mismatch |
| `sip_amount_selected` | User commits amount/frequency/scheme after validation | `amount_band`, `frequency`, `scheme_count`, `allocation_hash` | Affordability or choice-overload friction |
| `bank_verified` | Bank-link API/webhook confirms success | `provider`, `status`, `failure_code`, `latency_ms` | Bank coverage, provider, or consent issues |
| `mandate_completed` | Mandate provider webhook confirms UPI authorization | `provider`, `status`, `initiated_at`, `confirmed_at`, `latency_ms` | UPI handoff failure or delay |
| `additional_details_saved` | Server confirms required profile fields saved | `form_version`, `validation_error_count`, `nominee_selected` | Form burden, unnecessary fields |
| `investment_consent_verified` | Server verifies consent OTP | `attempt_count`, `retry_count`, `consent_version`, `failure_code` | Final-step OTP or trust friction |
| `sip_created` | Order service returns durable order ID | `order_id_hash`, `amount_band`, `frequency`, `status`, `failure_code` | Backend/order validation failure |
| `first_unit_credited` | RTA/ledger webhook or reconciled batch confirms credit | `order_id_hash`, `asset_type`, `credit_date`, `provider`, `latency_from_creation` | Settlement/reconciliation problem |

**Events deliberately cut**: intermediate screens (welcome/home, email OTP, individual SIP setup screens, bank-link tap, UPI app launch/return, nominee selection, dashboard view). These stay as properties or screen/error logs — useful for diagnosis, but they don't earn a slot under a 12-event cap. Nominee selection specifically becomes a property, not an event, since it's optional.

**Asynchronous design principle**: PAN verification, bank verification, mandate approval, and first-unit credit all fire from confirmed API responses, webhooks, or reconciliation jobs, never from a tap or an app return. Every async event stores `initiated_at` and `confirmed_at` and uses provider/order references for idempotency, with pending/failure states surfaced operationally (not silently dropped).

## Part B — Falsifiable hypothesis

**Hypothesis**: "Amount chosen" → "bank verified" is the biggest leak because users have already shown investment intent by this point, but bank linking introduces eligibility, privacy, provider-coverage, and handoff friction. The naive snapshot shows 1,192 fewer distinct users at bank verification.

**What would prove this wrong**: an ordered cohort analysis over a fully mature observation window shows a larger adjacent drop elsewhere, or bank-link initiation-to-success turns out to be high while some other stage has the lowest true conversion once retries and delayed callbacks are properly handled.

## Part C — North star and counter-metric

**North star**: weekly count of new users who reach first successful unit credit within 30 days of their first app open. This measures delivered investment value, not clicks or stated intent.

**Counter-metric**: 30-day early SIP failure/cancellation rate among users who were credited. Both metrics get sliced by acquisition source, amount band, provider, and configuration. The north star is only considered healthy if the counter-metric isn't materially worsening alongside it — otherwise the funnel could be "improved" by rushing people into a plan they cancel a week later.

## Part D — SQL approach

The accompanying SQL (`funnel_analysis.sql`) maps the 10 events to ordered stages, deduplicates to the first timestamp per user/event, and uses a recursive CTE to require that each stage's event occurs strictly after the previous validated stage's event for that same user. It returns three labeled result sets: the sequential funnel with step-over-step conversion, the median elapsed time (in seconds) from app open to first unit credit for users who completed all 10 stages in order, and the single largest absolute adjacent-stage user loss.

**Expected interpretation**: `mandate_completed` and `first_unit_credited` are confirmed by external providers (lender/mandate provider, RTA/asset ledger respectively) — their timestamps reflect operational completion, not a user action. Recent cohorts will look artificially incomplete unless the reporting window includes the expected settlement/credit turnaround time.

## Assumptions

- Event names exactly match the stage map.
- `user_id` is stable across sessions, devices, and provider callbacks.
- Repeated events are possible; SQL keeps the first timestamp per user per event.
- A sequential funnel counts a later stage only if it happened after the prior validated stage.
- First stage conversion is 100%; every later conversion is current-stage users ÷ previous-stage users.
- "Completed" = all 10 stages observed in order; median time is elapsed seconds from first app open to first unit credit.
- The observation window is mature enough that pending users aren't misread as failures.
- Timestamps share a consistent timezone and a trusted clock source.
- Test/internal users, duplicate callbacks, and retried events are excluded or deduplicated.
- If a user can create multiple SIPs, a `journey_id`/`order_id` is required to avoid mixing journeys.
- The independently-counted snapshot is not assumed sequential; it must be reconciled against the SQL's sequential result, not treated as equivalent to it.

## Data checks before trusting any result

Null checks, duplicate `event_id`s, duplicate provider references, timestamp timezone/clock skew, event-name drift, identity-stitching stability, test-user contamination, extraction completeness, callback delay handling, impossible sequences (a later stage timestamped before an earlier one), multi-SIP users without a journey key, and provider/RTA reconciliation gaps. Before reporting, a sample of individual user journeys should be manually traced against order and investment records, and raw row counts should be compared against distinct-user counts at every stage.
