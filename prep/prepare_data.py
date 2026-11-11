import csv
import gzip
import hashlib
import json
import os
import secrets
import sys

KEEP = ["trans_num", "split", "trans_ts", "card_id", "merchant", "category", "amt", "gender",
        "city_pop", "lat", "long", "merch_lat", "merch_long", "birth_year", "is_fraud"]
DROPPED = ["first", "last", "street", "city", "state", "zip", "job", "dob", "cc_num", "unix_time"]
SCHEMA = {"amt": "FLOAT", "city_pop": "INTEGER", "lat": "FLOAT", "long": "FLOAT", "merch_lat": "FLOAT",
          "merch_long": "FLOAT", "birth_year": "INTEGER", "is_fraud": "INTEGER", "trans_ts": "TIMESTAMP"}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data")


def salt():
    path = os.path.join(OUT, ".salt")
    if os.environ.get("FRAUD_SALT"):
        return os.environ["FRAUD_SALT"]
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(secrets.token_hex(16))
    return open(path).read().strip()


REQUIRED = {"trans_date_trans_time", "cc_num", "category", "amt", "dob", "trans_num", "is_fraud"}


def check_columns(path):
    with open(path, newline="", encoding="utf-8") as f:
        header = set(next(csv.reader(f)))
    if {"V1", "V2", "Class"} <= header:
        sys.exit("This is the anonymised European dataset (V1-V28). Use the Sparkov dataset "
                 "'Credit Card Transactions Fraud Detection' instead.")
    missing = REQUIRED - header
    if missing:
        sys.exit("Missing columns: " + ", ".join(sorted(missing)) + "\nFound: " + ", ".join(sorted(header)))


def cutoff_for(path, test_share):
    with open(path, newline="", encoding="utf-8") as f:
        stamps = sorted(r["trans_date_trans_time"] for r in csv.DictReader(f))
    return stamps[int(len(stamps) * (1 - test_share))]


def rows(path, split, key, cutoff=None):
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if cutoff:
                split = "test" if r["trans_date_trans_time"] >= cutoff else "train"
            yield {
                "trans_num": r["trans_num"],
                "split": split,
                "trans_ts": r["trans_date_trans_time"],
                "card_id": hashlib.sha256((key + r["cc_num"]).encode()).hexdigest()[:16],
                "merchant": r["merchant"].removeprefix("fraud_"),
                "category": r["category"],
                "amt": r["amt"],
                "gender": r["gender"],
                "city_pop": r["city_pop"],
                "lat": r["lat"],
                "long": r["long"],
                "merch_lat": r["merch_lat"],
                "merch_long": r["merch_long"],
                "birth_year": r["dob"][:4],
                "is_fraud": r["is_fraud"],
            }


def sources(paths, key):
    if len(paths) == 2:
        yield from rows(paths[0], "train", key)
        yield from rows(paths[1], "test", key)
    else:
        cutoff = cutoff_for(paths[0], 0.3)
        print(f"Single file: transactions from {cutoff} onwards form the out-of-time test set")
        yield from rows(paths[0], None, key, cutoff)


def main(paths):
    for path in paths:
        check_columns(path)
    os.makedirs(OUT, exist_ok=True)
    key = salt()
    counts = {}
    with gzip.open(os.path.join(OUT, "transactions.csv.gz"), "wt", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=KEEP)
        w.writeheader()
        for r in sources(paths, key):
            w.writerow(r)
            counts[r["split"]] = counts.get(r["split"], 0) + 1

    with open(os.path.join(OUT, "schema.json"), "w") as f:
        json.dump([{"name": c, "type": SCHEMA.get(c, "STRING")} for c in KEEP], f, indent=2)

    print(f"train={counts.get('train', 0)} test={counts.get('test', 0)}")
    print("Dropped PII: " + ", ".join(DROPPED))
    print("Hashed: cc_num -> card_id (salted SHA-256). Generalised: dob -> birth_year")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: python prep/prepare_data.py <transactions.csv> [test.csv]")
    main(sys.argv[1:])
