import math
import os
import re
import subprocess
import sys

import duckdb
import sqlglot

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ok = True


def expect(cond, msg):
    global ok
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    ok &= bool(cond)


def run_file(con, name, run_id):
    text = open(os.path.join(ROOT, "sql", name)).read()
    text = text.replace("FORMAT_TIMESTAMP('%Y%m%d_%H%M%S', CURRENT_TIMESTAMP())", f"'{run_id}'")
    for m in re.finditer(r"ASSERT\s+(.*?)\s+AS\s+'([^']*)';", text, re.S):
        cond = sqlglot.transpile(f"SELECT {m.group(1)}", read="bigquery", write="duckdb")[0]
        if not con.execute(cond).fetchone()[0]:
            raise AssertionError(m.group(2))
    text = re.sub(r"ASSERT\s+.*?\s+AS\s+'[^']*';", "", text, flags=re.S)
    for m in re.finditer(r"DECLARE\s+(\w+)\s+\w+\s+DEFAULT\s+\((.*?)\);", text, re.S):
        val = con.execute(sqlglot.transpile(m.group(2), read="bigquery", write="duckdb")[0]).fetchone()[0]
        text = re.sub(rf"\b{m.group(1)}\b", repr(val), text.replace(m.group(0), ""))
    text = re.sub(r"CREATE OR REPLACE MODEL[\s\S]*?;", "", text)
    for stmt in sqlglot.transpile(text, read="bigquery", write="duckdb"):
        stmt = stmt.replace('fraud_governance."INFORMATION_SCHEMA.COLUMNS"', "information_schema.columns")
        if stmt.strip():
            con.execute(stmt)


def stub_predictions(con):
    rows = con.execute("""
        SELECT trans_num, trans_ts, gender, age_band, category, is_fraud,
               log_amt, is_night, txn_count_24h, distance_km
        FROM fraud_governance.features WHERE split = 'test'""").fetchall()
    out = []
    for r in rows:
        tn, ts, g, ab, cat, y, la, night, cnt, dist = r
        base = 1 / (1 + math.exp(-(2.2 * la - 13.5)))
        chal = 1 / (1 + math.exp(-(2.0 * la + 2.5 * night + 0.8 * min(cnt, 5) - 15.0)))
        out += [("fraud_logreg", tn, ts, g, ab, cat, y, base), ("fraud_xgb", tn, ts, g, ab, cat, y, chal)]
    con.execute("""CREATE OR REPLACE TABLE fraud_governance.predictions (
        model_name VARCHAR, trans_num VARCHAR, trans_ts TIMESTAMP, gender VARCHAR, age_band VARCHAR,
        category VARCHAR, is_fraud INTEGER, fraud_score DOUBLE)""")
    con.executemany("INSERT INTO fraud_governance.predictions VALUES (?,?,?,?,?,?,?,?)", out)
    con.execute("""CREATE OR REPLACE TABLE fraud_governance.decision_threshold AS
        SELECT QUANTILE_DISC(fraud_score, 0.985) AS threshold FROM fraud_governance.predictions
        WHERE model_name = 'fraud_logreg'""")


def pipeline(mode, single=False):
    subprocess.run([sys.executable, os.path.join(ROOT, "tests", "make_test_data.py"), mode], check=True,
                   capture_output=True)
    files = [os.path.join(ROOT, "tests", "fraudTrain.csv"), os.path.join(ROOT, "tests", "fraudTest.csv")]
    if single:
        combined = os.path.join(ROOT, "tests", "credit_card_transactions.csv")
        with open(combined, "w") as out:
            out.write(open(files[0]).read())
            out.writelines(open(files[1]).readlines()[1:])
        files = [combined]
    prep = subprocess.run([sys.executable, os.path.join(ROOT, "prep", "prepare_data.py"), *files],
                          check=True, capture_output=True, text=True, env={**os.environ, "FRAUD_SALT": "test"}).stdout
    con = duckdb.connect()
    con.execute("CREATE SCHEMA fraud_governance")
    con.execute(f"""CREATE TABLE fraud_governance.raw_transactions AS
                    SELECT * FROM read_csv('{ROOT}/data/transactions.csv.gz', header=true)""")
    for i, f in enumerate(["00_setup.sql", "01_features.sql", "02_dq_checks.sql"]):
        run_file(con, f, f"20261111_10000{i}")
    try:
        run_file(con, "03_train.sql", "20261111_100003")
        gate = "passed"
    except AssertionError:
        return con, "blocked", prep
    stub_predictions(con)
    for i, f in enumerate(["05_evaluate.sql", "06_monitor.sql", "07_model_decision.sql"], start=4):
        run_file(con, f, f"20261111_10000{i}")
    return con, gate, prep


def show(con, q):
    print(con.execute(q).df().to_string(index=False))


print("=== Dirty data ===")
con, gate, _ = pipeline("dirty")
show(con, "SELECT check_id, status, rows_failed FROM fraud_governance.dq_results ORDER BY check_id")
expect(gate == "blocked", "quality gate blocks training when duplicate IDs exist")

print("\n=== Clean data ===")
con, gate, prep = pipeline("clean")
print(prep)
expect(gate == "passed", "quality gate passes on clean data")
dq = dict(con.execute("SELECT check_id, status FROM fraud_governance.dq_results").fetchall())
expect(all(v == "PASS" for v in dq.values()), "all 8 data quality checks pass")
cols = {r[0] for r in con.execute("SELECT column_name FROM information_schema.columns WHERE table_name='raw_transactions'").fetchall()}
expect(not cols & {"cc_num", "first", "last", "street", "dob", "job", "zip"}, "no direct identifiers reach the warehouse")
lens = con.execute("SELECT MIN(LENGTH(card_id)), MAX(LENGTH(card_id)) FROM fraud_governance.raw_transactions").fetchone()
expect(lens == (16, 16), "card numbers replaced by 16-char hashed IDs")
self_count = con.execute("""
    SELECT COUNT(*) FROM fraud_governance.features f
    WHERE txn_count_24h <> (SELECT COUNT(*) FROM fraud_governance.features g
                            WHERE g.card_id = f.card_id AND g.trans_ts < f.trans_ts
                              AND g.trans_ts >= f.trans_ts - INTERVAL 86400 SECOND)""").fetchone()[0]
expect(self_count == 0, "24h velocity counts only earlier transactions (no look-ahead)")
burst = con.execute("SELECT AVG(txn_count_24h) FILTER (WHERE is_fraud=1), AVG(txn_count_24h) FILTER (WHERE is_fraud=0) FROM fraud_governance.features").fetchone()
expect(burst[0] > burst[1], "fraud bursts show higher 24h velocity than normal spend")

print("\n-- model_metrics")
show(con, "SELECT model_name, n, n_fraud, alerts, precision, recall, fpr, alert_rate, auc FROM fraud_governance.model_metrics")
print("\n-- model_fairness")
show(con, "SELECT model_name, attribute, group_value, n_fraud, sufficient_sample, recall, recall_gap FROM fraud_governance.model_fairness ORDER BY 1,2,3")
print("\n-- feature_drift")
show(con, "SELECT * FROM fraud_governance.feature_drift ORDER BY feature")
print("\n-- vw_model_decision")
show(con, "SELECT model_name, auc, recall, alert_rate, max_recall_gap, failed_rules, decision, role FROM fraud_governance.vw_model_decision")

m = dict(con.execute("SELECT model_name, auc FROM fraud_governance.model_metrics").fetchall())
expect(m["fraud_xgb"] > m["fraud_logreg"], "AUC computed per model; stronger stub model scores higher")
from_lib = con.execute("""
    WITH p AS (SELECT is_fraud, fraud_score FROM fraud_governance.predictions WHERE model_name='fraud_xgb')
    SELECT AVG(CASE WHEN a.fraud_score > b.fraud_score THEN 1.0 WHEN a.fraud_score = b.fraud_score THEN 0.5 ELSE 0 END)
    FROM p a, p b WHERE a.is_fraud = 1 AND b.is_fraud = 0""").fetchone()[0]
expect(abs(from_lib - m["fraud_xgb"]) < 0.01, f"AUC matches pairwise definition ({from_lib:.4f} vs {m['fraud_xgb']:.4f})")
expect(con.execute("SELECT COUNT(*) FROM fraud_governance.feature_drift").fetchone()[0] == 5, "PSI computed for 5 features")
expect(con.execute("SELECT COUNT(DISTINCT attribute) FROM fraud_governance.model_fairness").fetchone()[0] == 2, "fairness tested on gender and age band")
d = con.execute("SELECT COUNT(*), SUM(CASE WHEN decision IN ('APPROVED','REJECTED') THEN 1 ELSE 0 END) FROM fraud_governance.vw_model_decision").fetchone()
expect(d[0] == 2 and d[1] == 2, "every model gets an approval decision with reasons")
gap = con.execute("""SELECT MAX(ABS(recall_gap - g)) FROM fraud_governance.model_fairness
    JOIN (SELECT model_name, attribute, MAX(recall) - MIN(recall) AS g FROM fraud_governance.model_fairness
          WHERE sufficient_sample GROUP BY 1, 2) USING (model_name, attribute)""").fetchone()[0]
expect(gap < 1e-6, "fairness gaps use only groups with 30+ fraud cases")
appr = con.execute("SELECT COUNT(*) FROM fraud_governance.vw_model_decision WHERE failed_rules = '' AND decision = 'APPROVED'").fetchone()[0]
expect(appr == 2, "models meeting every policy rule are approved")
ar = con.execute("SELECT MAX(alert_rate) FROM fraud_governance.model_metrics WHERE model_name = 'fraud_logreg'").fetchone()[0]
expect(ar <= 0.02, f"threshold keeps alert rate within policy ({ar})")
champ = con.execute("SELECT COUNT(*) FROM fraud_governance.vw_model_decision WHERE role = 'CHAMPION'").fetchone()[0]
expect(champ <= 1, "at most one champion model is selected")
print("\n=== Single combined file ===")
con1, gate1, prep1 = pipeline("clean", single=True)
print(prep1)
dq1 = dict(con1.execute("SELECT check_id, status FROM fraud_governance.dq_results").fetchall())
split1 = con1.execute("SELECT ROUND(AVG(CASE WHEN split='test' THEN 1 ELSE 0 END), 2) FROM fraud_governance.raw_transactions").fetchone()[0]
expect(gate1 == "passed" and dq1["DQ06"] == "PASS", "single file is split out-of-time and passes the checks")
expect(abs(split1 - 0.3) < 0.02, f"single file puts about 30% in the test set ({split1})")

con.execute("UPDATE fraud_governance.model_metrics SET recall = 0.2 WHERE model_name = 'fraud_logreg'")
rej = con.execute("SELECT decision, failed_rules FROM fraud_governance.vw_model_decision WHERE model_name = 'fraud_logreg'").fetchone()
expect(rej == ("REJECTED", "recall below policy"), "a model breaching policy is rejected with the reason stated")
print("\nALL TESTS PASSED" if ok else "\nSOME TESTS FAILED")
sys.exit(0 if ok else 1)
