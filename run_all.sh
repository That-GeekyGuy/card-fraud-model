#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:?Give your GCP project id as the first argument}"
shift
CHALLENGER=false
FILES=()
for a in "$@"; do
  if [[ "$a" == "--challenger" ]]; then CHALLENGER=true; else FILES+=("$a"); fi
done
[[ ${#FILES[@]} -ge 1 ]] || { echo "Give one or two Kaggle CSV files"; exit 1; }

cd "$(dirname "$0")"
DS=fraud_governance
BQ=(bq --project_id="$PROJECT" --location=US)

run_sql() {
  echo ">> $1"
  "${BQ[@]}" query --use_legacy_sql=false --format=none < "sql/$1"
}

show() {
  echo
  echo "== $1 =="
  "${BQ[@]}" query --use_legacy_sql=false --format=pretty --max_rows=50 "$2"
}

command -v bq >/dev/null || { echo "Install the Google Cloud SDK first (or use Cloud Shell)"; exit 1; }
gcloud config set project "$PROJECT" >/dev/null

echo ">> Preparing data"
python3 prep/prepare_data.py "${FILES[@]}"

run_sql 00_setup.sql

echo ">> Loading data/transactions.csv.gz"
"${BQ[@]}" load --replace --source_format=CSV --skip_leading_rows=1 \
  "$DS.raw_transactions" data/transactions.csv.gz data/schema.json

run_sql 01_features.sql
run_sql 02_dq_checks.sql

show "Data quality" "
SELECT check_id, severity, rows_failed, status
FROM $DS.dq_results
WHERE run_id = (SELECT MAX(run_id) FROM $DS.dq_results)
ORDER BY check_id"

run_sql 03_train.sql
run_sql 03c_threshold.sql
run_sql 04_score.sql

if $CHALLENGER; then
  run_sql 03b_train_challenger.sql
  run_sql 04b_score_challenger.sql
fi

run_sql 05_evaluate.sql
run_sql 06_monitor.sql
run_sql 07_model_decision.sql

show "Threshold" "SELECT * FROM $DS.decision_threshold"
show "Model metrics" "SELECT * FROM $DS.model_metrics ORDER BY run_id DESC LIMIT 4"
show "Fairness" "SELECT * FROM $DS.model_fairness"
show "Drift (PSI)" "SELECT * FROM $DS.feature_drift"
show "Decision" "SELECT * FROM $DS.vw_model_decision"

echo
echo "Done. Copy these numbers into docs/model_card.md"
