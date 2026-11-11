CREATE OR REPLACE TABLE fraud_governance.predictions AS
SELECT * FROM fraud_governance.predictions WHERE model_name != 'fraud_xgb'
UNION ALL
SELECT
  'fraud_xgb' AS model_name,
  trans_num, trans_ts, gender, age_band, category, is_fraud,
  (SELECT prob FROM UNNEST(predicted_is_fraud_probs) WHERE label = 1) AS fraud_score
FROM ML.PREDICT(
  MODEL fraud_governance.fraud_xgb,
  (SELECT * FROM fraud_governance.features WHERE split = 'test')
);
