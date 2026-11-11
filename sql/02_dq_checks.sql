CREATE OR REPLACE TABLE fraud_governance.dq_results AS
WITH
raw AS (SELECT * FROM fraud_governance.raw_transactions),
pii_columns AS (
  SELECT column_name
  FROM fraud_governance.INFORMATION_SCHEMA.COLUMNS
  WHERE table_name = 'raw_transactions'
    AND LOWER(column_name) IN ('cc_num', 'first', 'last', 'street', 'zip', 'dob', 'job')
),
checks AS (
  SELECT 'DQ01' AS check_id, 'Transaction IDs are unique' AS description, 'FAIL' AS severity,
         COUNT(*) AS rows_tested, COUNT(*) - COUNT(DISTINCT trans_num) AS rows_failed
  FROM raw
  UNION ALL
  SELECT 'DQ02', 'Key fields are present', 'FAIL', COUNT(*),
         COUNTIF(trans_ts IS NULL OR card_id IS NULL OR amt IS NULL OR category IS NULL OR is_fraud IS NULL)
  FROM raw
  UNION ALL
  SELECT 'DQ03', 'Amounts are positive', 'FAIL', COUNT(*), COUNTIF(amt <= 0)
  FROM raw
  UNION ALL
  SELECT 'DQ04', 'Label is 0 or 1', 'FAIL', COUNT(*), COUNTIF(is_fraud NOT IN (0, 1))
  FROM raw
  UNION ALL
  SELECT 'DQ05', 'Coordinates are within valid ranges', 'WARN', COUNT(*),
         COUNTIF(ABS(lat) > 90 OR ABS(merch_lat) > 90 OR ABS(long) > 180 OR ABS(merch_long) > 180)
  FROM raw
  UNION ALL
  SELECT 'DQ06', 'Test data is strictly later than training data (out-of-time)', 'FAIL',
         COUNTIF(split = 'test'),
         COUNTIF(split = 'test' AND trans_ts <= (SELECT MAX(trans_ts) FROM raw WHERE split = 'train'))
  FROM raw
  UNION ALL
  SELECT 'DQ07', 'Training fraud rate between 0.1% and 5%', 'WARN', COUNTIF(split = 'train'),
         IF(SAFE_DIVIDE(COUNTIF(split = 'train' AND is_fraud = 1), COUNTIF(split = 'train')) BETWEEN 0.001 AND 0.05,
            0, COUNTIF(split = 'train'))
  FROM raw
  UNION ALL
  SELECT 'DQ08', 'No direct identifiers (names, card numbers, addresses, DOB) in the warehouse', 'FAIL',
         (SELECT COUNT(*) FROM fraud_governance.INFORMATION_SCHEMA.COLUMNS WHERE table_name = 'raw_transactions'),
         (SELECT COUNT(*) FROM pii_columns)
)
SELECT * FROM fraud_governance.dq_results
UNION ALL
SELECT FORMAT_TIMESTAMP('%Y%m%d_%H%M%S', CURRENT_TIMESTAMP()), check_id, description, severity,
       rows_tested, rows_failed, IF(rows_failed = 0, 'PASS', severity), CURRENT_TIMESTAMP()
FROM checks;
