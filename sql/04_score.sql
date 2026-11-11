CREATE OR REPLACE TABLE fraud_governance.predictions AS
SELECT
  'fraud_logreg' AS model_name,
  trans_num, trans_ts, gender, age_band, category, is_fraud,
  (SELECT prob FROM UNNEST(predicted_is_fraud_probs) WHERE label = 1) AS fraud_score
FROM ML.PREDICT(
  MODEL fraud_governance.fraud_logreg,
  (SELECT * FROM fraud_governance.features WHERE split = 'test')
);
