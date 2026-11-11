CREATE OR REPLACE TABLE fraud_governance.threshold_candidates AS
WITH
val AS (
  SELECT age_band, is_fraud,
    (SELECT prob FROM UNNEST(predicted_is_fraud_probs) WHERE label = 1) AS fraud_score
  FROM ML.PREDICT(
    MODEL fraud_governance.fraud_logreg,
    (SELECT * FROM fraud_governance.features
     WHERE split = 'train' AND trans_ts >= TIMESTAMP '2020-04-01'))
),
cand AS (SELECT thr FROM UNNEST(GENERATE_ARRAY(0.50, 0.99, 0.01)) AS thr),
by_age AS (
  SELECT c.thr, v.age_band,
    COUNTIF(v.is_fraud = 1) AS n_fraud,
    SAFE_DIVIDE(COUNTIF(v.fraud_score >= c.thr AND v.is_fraud = 1), COUNTIF(v.is_fraud = 1)) AS recall
  FROM val v CROSS JOIN cand c
  GROUP BY c.thr, v.age_band
),
gap AS (
  SELECT thr,
    MAX(IF(n_fraud >= 30, recall, NULL)) - MIN(IF(n_fraud >= 30, recall, NULL)) AS recall_gap
  FROM by_age GROUP BY thr
),
overall AS (
  SELECT c.thr,
    COUNT(*) AS n,
    COUNTIF(v.fraud_score >= c.thr) / COUNT(*) AS alert_rate,
    SAFE_DIVIDE(COUNTIF(v.fraud_score >= c.thr AND v.is_fraud = 1), COUNTIF(v.is_fraud = 1)) AS recall
  FROM val v CROSS JOIN cand c
  GROUP BY c.thr
)
SELECT o.thr, o.n, o.alert_rate, o.recall, g.recall_gap,
       o.alert_rate <= 0.015 AND o.recall >= 0.60 AS eligible
FROM overall o JOIN gap g USING (thr);

CREATE OR REPLACE TABLE fraud_governance.decision_threshold AS
SELECT thr AS threshold, alert_rate AS val_alert_rate, recall AS val_recall, recall_gap AS val_recall_gap
FROM fraud_governance.threshold_candidates
WHERE eligible
ORDER BY recall_gap, thr
LIMIT 1;
