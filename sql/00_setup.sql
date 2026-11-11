CREATE SCHEMA IF NOT EXISTS fraud_governance;

CREATE TABLE IF NOT EXISTS fraud_governance.dq_results (
  run_id      STRING,
  check_id    STRING,
  description STRING,
  severity    STRING,
  rows_tested INT64,
  rows_failed INT64,
  status      STRING,
  run_ts      TIMESTAMP
);

CREATE TABLE IF NOT EXISTS fraud_governance.model_metrics (
  run_id      STRING,
  model_name  STRING,
  n           INT64,
  n_fraud     INT64,
  alerts      INT64,
  tp          INT64,
  fp          INT64,
  fn          INT64,
  precision   FLOAT64,
  recall      FLOAT64,
  f1          FLOAT64,
  fpr         FLOAT64,
  alert_rate  FLOAT64,
  auc         FLOAT64,
  run_ts      TIMESTAMP
);
