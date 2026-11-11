CREATE OR REPLACE TABLE fraud_governance.features AS
WITH base AS (
  SELECT
    *,
    UNIX_SECONDS(trans_ts) AS ts_sec
  FROM fraud_governance.raw_transactions
),
windowed AS (
  SELECT
    *,
    COUNT(*) OVER w24 AS txn_count_24h,
    SUM(amt) OVER w24 AS amt_sum_24h,
    AVG(amt) OVER w30 AS avg_amt_30d,
    ts_sec - LAG(ts_sec) OVER (PARTITION BY card_id ORDER BY ts_sec) AS secs_since_last
  FROM base
  WINDOW
    w24 AS (PARTITION BY card_id ORDER BY ts_sec RANGE BETWEEN 86400 PRECEDING AND 1 PRECEDING),
    w30 AS (PARTITION BY card_id ORDER BY ts_sec RANGE BETWEEN 2592000 PRECEDING AND 1 PRECEDING)
)
SELECT
  trans_num,
  split,
  trans_ts,
  card_id,
  gender,
  EXTRACT(YEAR FROM trans_ts) - birth_year AS age,
  CASE
    WHEN EXTRACT(YEAR FROM trans_ts) - birth_year < 30 THEN '<30'
    WHEN EXTRACT(YEAR FROM trans_ts) - birth_year < 45 THEN '30-44'
    WHEN EXTRACT(YEAR FROM trans_ts) - birth_year < 60 THEN '45-59'
    ELSE '60+'
  END AS age_band,
  category,
  amt,
  LN(1 + amt) AS log_amt,
  EXTRACT(HOUR FROM trans_ts) AS hour,
  IF(EXTRACT(HOUR FROM trans_ts) >= 22 OR EXTRACT(HOUR FROM trans_ts) < 4, 1, 0) AS is_night,
  EXTRACT(DAYOFWEEK FROM trans_ts) AS day_of_week,
  LN(1 + city_pop) AS log_city_pop,
  6371 * 2 * ASIN(SQRT(
    POW(SIN((merch_lat - lat) * ACOS(-1) / 360), 2)
    + COS(lat * ACOS(-1) / 180) * COS(merch_lat * ACOS(-1) / 180)
    * POW(SIN((merch_long - long) * ACOS(-1) / 360), 2)
  )) AS distance_km,
  COALESCE(txn_count_24h, 0) AS txn_count_24h,
  COALESCE(amt_sum_24h, 0) AS amt_sum_24h,
  COALESCE(SAFE_DIVIDE(amt, avg_amt_30d), 1) AS amt_vs_30d_avg,
  LN(1 + COALESCE(secs_since_last, 2592000)) AS log_secs_since_last,
  is_fraud
FROM windowed;
