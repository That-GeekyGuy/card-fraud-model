CREATE OR REPLACE TABLE fraud_governance.feature_drift AS
WITH
binned AS (
  SELECT split, 'amount' AS feature,
    CASE WHEN amt < 10 THEN '01 <10' WHEN amt < 50 THEN '02 10-50' WHEN amt < 100 THEN '03 50-100'
         WHEN amt < 500 THEN '04 100-500' ELSE '05 500+' END AS bin
  FROM fraud_governance.features
  UNION ALL
  SELECT split, 'hour',
    CASE WHEN hour < 6 THEN '01 00-05' WHEN hour < 12 THEN '02 06-11' WHEN hour < 18 THEN '03 12-17'
         ELSE '04 18-23' END
  FROM fraud_governance.features
  UNION ALL
  SELECT split, 'category', category
  FROM fraud_governance.features
  UNION ALL
  SELECT split, 'txn_count_24h',
    CASE WHEN txn_count_24h = 0 THEN '01 0' WHEN txn_count_24h <= 2 THEN '02 1-2'
         WHEN txn_count_24h <= 5 THEN '03 3-5' ELSE '04 6+' END
  FROM fraud_governance.features
  UNION ALL
  SELECT split, 'distance_km',
    CASE WHEN distance_km < 25 THEN '01 <25' WHEN distance_km < 75 THEN '02 25-75'
         WHEN distance_km < 125 THEN '03 75-125' ELSE '04 125+' END
  FROM fraud_governance.features
),
counts AS (
  SELECT feature, bin, COUNTIF(split = 'train') AS train_n, COUNTIF(split = 'test') AS test_n
  FROM binned
  GROUP BY feature, bin
),
shares AS (
  SELECT
    feature, bin,
    GREATEST(SAFE_DIVIDE(train_n, SUM(train_n) OVER (PARTITION BY feature)), 0.0001) AS expected,
    GREATEST(SAFE_DIVIDE(test_n, SUM(test_n) OVER (PARTITION BY feature)), 0.0001) AS actual
  FROM counts
),
psi_by_feature AS (
  SELECT feature, ROUND(SUM((actual - expected) * LN(actual / expected)), 4) AS psi
  FROM shares
  GROUP BY feature
)
SELECT
  feature,
  psi,
  CASE WHEN psi < 0.1 THEN 'STABLE' WHEN psi < 0.25 THEN 'WATCH' ELSE 'DRIFT' END AS status
FROM psi_by_feature;
