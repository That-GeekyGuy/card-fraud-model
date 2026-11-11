import csv
import os
import random
import sys
from datetime import datetime, timedelta

random.seed(11)
mode = sys.argv[1] if len(sys.argv) > 1 else "clean"
HERE = os.path.dirname(os.path.abspath(__file__))
COLS = ["", "trans_date_trans_time", "cc_num", "merchant", "category", "amt", "first", "last", "gender",
        "street", "city", "state", "zip", "lat", "long", "city_pop", "job", "dob", "trans_num",
        "unix_time", "merch_lat", "merch_long", "is_fraud"]
CATS = ["grocery_pos", "gas_transport", "home", "shopping_pos", "kids_pets", "entertainment",
        "food_dining", "personal_care", "health_fitness", "misc_pos", "shopping_net", "misc_net", "travel"]
START, SPLIT, END = datetime(2019, 1, 1), datetime(2020, 6, 21), datetime(2020, 12, 31)

cards = []
for i in range(500):
    cards.append({
        "cc_num": str(4000000000000000 + i * 7919),
        "first": f"First{i}", "last": f"Last{i}", "gender": random.choice("MF"),
        "lat": random.uniform(30, 45), "long": random.uniform(-120, -80),
        "city_pop": random.randint(500, 2000000),
        "dob": f"{random.randint(1940, 2002)}-0{random.randint(1, 9)}-1{random.randint(0, 9)}",
    })

txns = []
for c in cards:
    t = START + timedelta(hours=random.uniform(0, 72))
    while t < END:
        txns.append((t, c, random.choice(CATS[:10]), round(random.lognormvariate(3.5, 0.8), 2), 0, 0.3))
        t += timedelta(hours=random.expovariate(1 / 40))
    if random.random() < 0.6:
        b = START + timedelta(days=random.uniform(30, (END - START).days - 5))
        b = b.replace(hour=random.choice([22, 23, 0, 1, 2]))
        for k in range(random.randint(3, 6)):
            txns.append((b + timedelta(minutes=17 * k), c, random.choice(["shopping_net", "misc_net"]),
                         round(random.uniform(300, 1200), 2), 1, random.uniform(1.5, 2.5)))

txns.sort(key=lambda x: x[0])
train, test = [], []
for n, (t, c, cat, amt, fraud, off) in enumerate(txns):
    row = {"": n, "trans_date_trans_time": t.strftime("%Y-%m-%d %H:%M:%S"), "cc_num": c["cc_num"],
           "merchant": f"fraud_Merchant {random.randint(1, 300)}", "category": cat, "amt": amt,
           "first": c["first"], "last": c["last"], "gender": c["gender"], "street": "1 Main St",
           "city": "Town", "state": "CA", "zip": "90001", "lat": round(c["lat"], 4), "long": round(c["long"], 4),
           "city_pop": c["city_pop"], "job": "Engineer", "dob": c["dob"], "trans_num": f"t{n:08d}",
           "unix_time": int(t.timestamp()), "merch_lat": round(c["lat"] + random.uniform(-off, off), 4),
           "merch_long": round(c["long"] + random.uniform(-off, off), 4), "is_fraud": fraud}
    (train if t < SPLIT else test).append(row)

if mode == "dirty":
    train.append(dict(train[5]))

for name, data in (("fraudTrain.csv", train), ("fraudTest.csv", test)):
    with open(os.path.join(HERE, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        w.writerows(data)
print(f"train={len(train)} test={len(test)} fraud={sum(r['is_fraud'] for r in train + test)}")
