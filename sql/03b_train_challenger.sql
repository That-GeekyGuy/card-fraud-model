ASSERT NOT EXISTS (
  SELECT 1 FROM fraud_governance.dq_results
  WHERE run_id = (SELECT MAX(run_id) FROM fraud_governance.dq_results)
    AND status = 'FAIL'
) AS 'Quality gate: latest data quality run has FAIL results.';

CREATE OR REPLACE MODEL fraud_governance.fraud_xgb
OPTIONS (
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['is_fraud'],
  auto_class_weights = TRUE,
  max_iterations = 50,
  data_split_method = 'NO_SPLIT'
) AS
SELECT
  category, log_amt, hour, is_night, day_of_week, log_city_pop, distance_km,
  txn_count_24h, amt_sum_24h, amt_vs_30d_avg, log_secs_since_last, is_fraud
FROM fraud_governance.features
WHERE split = 'train';
