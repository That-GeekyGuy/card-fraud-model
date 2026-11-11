CREATE OR REPLACE VIEW fraud_governance.vw_model_decision AS
WITH
policy AS (
  SELECT 0.85 AS min_auc, 0.60 AS min_recall, 0.02 AS max_alert_rate, 0.10 AS max_recall_gap
),
latest AS (
  SELECT * FROM fraud_governance.model_metrics
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY model_name ORDER BY run_ts DESC) = 1
),
fairness AS (
  SELECT model_name, COALESCE(MAX(recall_gap), 0) AS max_recall_gap
  FROM fraud_governance.model_fairness
  GROUP BY model_name
),
drift AS (
  SELECT COUNTIF(status = 'DRIFT') AS drifted_features FROM fraud_governance.feature_drift
),
evaluated AS (
  SELECT
    l.model_name, l.auc, l.recall, l.precision, l.alert_rate, f.max_recall_gap, d.drifted_features,
    RTRIM(CONCAT(
      IF(l.auc < p.min_auc, 'AUC below policy; ', ''),
      IF(l.recall < p.min_recall, 'recall below policy; ', ''),
      IF(l.alert_rate > p.max_alert_rate, 'alert rate above policy; ', ''),
      IF(f.max_recall_gap > p.max_recall_gap, 'recall gap across groups above policy; ', ''),
      IF(d.drifted_features > 0, 'feature drift detected; ', '')
    ), '; ') AS failed_rules
  FROM latest l
  JOIN fairness f USING (model_name)
  CROSS JOIN drift d
  CROSS JOIN policy p
)
SELECT
  *,
  IF(failed_rules = '', 'APPROVED', 'REJECTED') AS decision,
  IF(failed_rules = '' AND auc = MAX(IF(failed_rules = '', auc, NULL)) OVER (), 'CHAMPION', NULL) AS role
FROM evaluated;
