DECLARE thr FLOAT64 DEFAULT (SELECT threshold FROM fraud_governance.decision_threshold);
CREATE OR REPLACE TABLE fraud_governance.model_metrics AS
WITH
scored AS (
  SELECT *, IF(fraud_score >= thr, 1, 0) AS alert
  FROM fraud_governance.predictions
),
ranked AS (
  SELECT model_name, is_fraud,
         RANK() OVER (PARTITION BY model_name ORDER BY fraud_score) AS r
  FROM fraud_governance.predictions
),
auc AS (
  SELECT
    model_name,
    SAFE_DIVIDE(
      SUM(IF(is_fraud = 1, CAST(r AS FLOAT64), 0))
        - COUNTIF(is_fraud = 1) * (COUNTIF(is_fraud = 1) + 1) / 2,
      CAST(COUNTIF(is_fraud = 1) AS FLOAT64) * COUNTIF(is_fraud = 0)
    ) AS auc
  FROM ranked
  GROUP BY model_name
),
confusion AS (
  SELECT
    model_name,
    COUNT(*) AS n,
    COUNTIF(is_fraud = 1) AS n_fraud,
    COUNTIF(alert = 1) AS alerts,
    COUNTIF(alert = 1 AND is_fraud = 1) AS tp,
    COUNTIF(alert = 1 AND is_fraud = 0) AS fp,
    COUNTIF(alert = 0 AND is_fraud = 1) AS fn,
    COUNTIF(is_fraud = 0) AS negatives
  FROM scored
  GROUP BY model_name
)
SELECT * FROM fraud_governance.model_metrics
UNION ALL
SELECT
  FORMAT_TIMESTAMP('%Y%m%d_%H%M%S', CURRENT_TIMESTAMP()),
  c.model_name, c.n, c.n_fraud, c.alerts, c.tp, c.fp, c.fn,
  ROUND(SAFE_DIVIDE(c.tp, c.tp + c.fp), 4),
  ROUND(SAFE_DIVIDE(c.tp, c.tp + c.fn), 4),
  ROUND(SAFE_DIVIDE(2 * c.tp, 2 * c.tp + c.fp + c.fn), 4),
  ROUND(SAFE_DIVIDE(c.fp, c.negatives), 4),
  ROUND(SAFE_DIVIDE(c.alerts, c.n), 4),
  ROUND(a.auc, 4),
  CURRENT_TIMESTAMP()
FROM confusion c
JOIN auc a USING (model_name);

CREATE OR REPLACE TABLE fraud_governance.model_fairness AS
WITH
scored AS (
  SELECT *, IF(fraud_score >= thr, 1, 0) AS alert
  FROM fraud_governance.predictions
),
grouped_rows AS (
  SELECT model_name, 'gender' AS attribute, gender AS group_value, is_fraud, alert FROM scored
  UNION ALL
  SELECT model_name, 'age_band', age_band, is_fraud, alert FROM scored
),
by_group AS (
  SELECT
    model_name, attribute, group_value,
    COUNT(*) AS n,
    COUNTIF(is_fraud = 1) AS n_fraud,
    ROUND(SAFE_DIVIDE(COUNTIF(alert = 1 AND is_fraud = 1), COUNTIF(is_fraud = 1)), 4) AS recall,
    ROUND(SAFE_DIVIDE(COUNTIF(alert = 1 AND is_fraud = 0), COUNTIF(is_fraud = 0)), 4) AS fpr
  FROM grouped_rows
  GROUP BY model_name, attribute, group_value
)
SELECT
  *,
  n_fraud >= 30 AS sufficient_sample,
  ROUND(MAX(IF(n_fraud >= 30, recall, NULL)) OVER (PARTITION BY model_name, attribute)
      - MIN(IF(n_fraud >= 30, recall, NULL)) OVER (PARTITION BY model_name, attribute), 4) AS recall_gap,
  ROUND(MAX(IF(n_fraud >= 30, fpr, NULL)) OVER (PARTITION BY model_name, attribute)
      - MIN(IF(n_fraud >= 30, fpr, NULL)) OVER (PARTITION BY model_name, attribute), 4) AS fpr_gap
FROM by_group;

CREATE OR REPLACE TABLE fraud_governance.model_monthly AS
SELECT
  model_name,
  DATE_TRUNC(DATE(trans_ts), MONTH) AS month,
  COUNT(*) AS n,
  COUNTIF(is_fraud = 1) AS n_fraud,
  ROUND(SAFE_DIVIDE(COUNTIF(fraud_score >= thr AND is_fraud = 1), COUNTIF(is_fraud = 1)), 4) AS recall,
  ROUND(SAFE_DIVIDE(COUNTIF(fraud_score >= thr AND is_fraud = 1), COUNTIF(fraud_score >= thr)), 4) AS precision,
  ROUND(SAFE_DIVIDE(COUNTIF(fraud_score >= thr), COUNT(*)), 4) AS alert_rate
FROM fraud_governance.predictions
GROUP BY model_name, month;
