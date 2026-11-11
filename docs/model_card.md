# Model Card: Card Fraud Detection

Run 20261111_093734 on BigQuery (sandbox, project `card-fraud-gov-87664`). All values come from `vw_model_decision`, `model_metrics`, `model_fairness`, `feature_drift`, `decision_threshold` and `features`.

## Purpose
Flag card transactions for fraud review. Decision support only; no automatic declines.

## Data
Synthetic card transactions (Sparkov, Kaggle, CC0). 1,852,394 transactions in total. Direct identifiers removed before loading; card numbers replaced with salted hashes.

| Split | Rows | Frauds | Fraud rate | From | To | Use |
|---|---|---|---|---|---|---|
| Fit | 1,097,693 | 6,343 | 0.578% | 2019-01-01 00:00:18 | 2020-03-31 23:59:55 | Model training |
| Validation | 198,982 | 1,163 | 0.584% | 2020-04-01 00:03:39 | 2020-06-21 12:13:37 | Threshold selection only |
| Test | 555,719 | 2,145 | 0.386% | 2020-06-21 12:14:25 | 2020-12-31 23:59:34 | Out-of-time evaluation |

All 8 data quality checks passed (DQ01-DQ08).

## Features
Category, amount, hour, night flag, day of week, city population, cardholder-to-merchant distance, 24-hour transaction count and spend, amount versus 30-day average, time since last transaction.

Excluded: gender, age. Used only for fairness testing.

## Threshold selection
The alert threshold is chosen on the validation slice only; the test set plays no part. Rule: validation alert rate at most 1.5% and recall at least 0.60, then the smallest age-band recall gap. Chosen threshold: **0.91** (validation alert rate 0.93%, recall 0.681, age-band recall gap 0.049). Candidates are in `threshold_candidates`.

An earlier run at a fixed 0.5 threshold was REJECTED (alert rate 4.55% against the 2% limit). A threshold of 0.75, chosen from train-score quantiles, was also REJECTED (age-band recall gap 0.1029 against 0.10).

## Performance (test set, threshold 0.91)

| Model | AUC | Precision | Recall | Alert rate | Decision |
|---|---|---|---|---|---|
| fraud_logreg | 0.9802 | 0.3229 | 0.7082 | 0.85% | APPROVED (CHAMPION) |
| fraud_xgb | not run | not run | not run | not run | not run |

Confusion matrix (n=555,719): TP 1,519, FP 3,185, FN 626, 4,704 alerts, FPR 0.58%. `failed_rules`: none. The challenger (boosted tree) was not trained, to stay within the free tier.

## Policy thresholds
AUC at least 0.85, recall at least 0.60, alert rate at most 2%, recall gap across groups at most 0.10 (groups with 30+ fraud cases), no feature with PSI of 0.25 or more.

## Fairness
Groups with fewer than 30 frauds are marked insufficient and excluded from the gaps; none were affected (all groups have 302 or more).

| Attribute | Group | Frauds | Recall | FPR |
|---|---|---|---|---|
| Gender | F | 1,164 | 0.6967 | 0.0060 |
| Gender | M | 981 | 0.7217 | 0.0055 |
| Age band | <30 | 302 | 0.7781 | 0.0058 |
| Age band | 30-44 | 645 | 0.7054 | 0.0062 |
| Age band | 45-59 | 623 | 0.6790 | 0.0063 |
| Age band | 60+ | 575 | 0.7061 | 0.0044 |

Largest recall gap by gender: 0.0250 (FPR gap 0.0005). By age band: 0.0991 (FPR gap 0.0019).

The age-band recall gap passes by a narrow margin (0.0991 against 0.10). On validation it was 0.049, so the gap is noisy and the result should be watched in production.

## Drift
Features with PSI of 0.1 or more: none. 0 features drifted.

| Feature | PSI | Status |
|---|---|---|
| amount | 0.0001 | STABLE |
| category | 0.0000 | STABLE |
| distance_km | 0.0000 | STABLE |
| hour | 0.0000 | STABLE |
| txn_count_24h | 0.0416 | STABLE |

## Limitations
Synthetic data; fraud patterns may be simpler than real ones. Fixed 0.91 threshold. No cost weighting between missed fraud and false alerts. Recall fell from 0.896 at a 0.5 threshold to 0.708 to meet the alert-rate limit, so about 29% of test frauds are missed. The age-band recall gap passes narrowly.
