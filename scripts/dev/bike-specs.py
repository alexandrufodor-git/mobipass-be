#!/usr/bin/env python3
# ===========================================================================
# bike-specs.py — propose weight / range / charge time for catalog bikes the
# BellaBike sync leaves NULL (the app shows N/A). Read-only: prints a table +
# an UPDATE to review, never writes.
#
# BellaBike has no attributes for these; weight (sometimes range) is only free
# text in the Page Builder description. merge_bike_offers never writes these
# three columns, so manual values survive the nightly sync (power_wh does not).
#
# Prefer the maker's spec page over every estimate here; never estimate weight.
#
# USAGE
#   ./bike-specs.py company "<company name>"     the company's copilot_bike_ids
#   ./bike-specs.py ids <uuid> [<uuid>...]
#   --charger-a N                                charger amps for the estimate (default 4)
# ===========================================================================
import html, json, os, re, subprocess, sys

# "Up to" range, the commute case: Kross 800 Wh = 120 km, Kreidler 400 Wh = 60 km (official).
# Not review numbers — those are full-assist eMTB laps (Levo 840 Wh ≈ 41 km).
WH_PER_KM = 6.6
CHARGE_V = 42       # 36V pack full-charge voltage
CHARGE_LOSS = 1.25  # fits Avinox 800/4A = 6 h, Bosch 400/4A = 3.5 h, Levo 840/4A ≈ 5 h


def query(sql):
    r = subprocess.run(["supabase", "db", "query", "--linked", sql], capture_output=True, text=True,
                       cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
    if r.returncode:
        sys.exit(r.stderr.strip().splitlines()[-2])
    return json.loads(r.stdout[r.stdout.index("{"):])["rows"]


def plain(desc):
    t = html.unescape(html.unescape(desc or ""))
    t = re.sub(r"<style.*?</style>", "", t, flags=re.S)
    t = re.sub(r"<br\s*/?>|<[^>]+>", "\n", t)
    return [l.strip() for l in t.split("\n") if l.strip()]


def labelled(lines, label):
    # "Greutate: 24 kg" or "Greutate:" with the value on the next line
    for i, l in enumerate(lines):
        m = re.match(rf"{label}[^:]*:\s*(.*)", l, re.I)
        if m and not re.search(r"maxim|suportat", l, re.I):
            v = m.group(1) or (lines[i + 1] if i + 1 < len(lines) else "")
            n = re.search(r"(\d+(?:[.,]\d+)?)", v)
            if n:
                return float(n.group(1).replace(",", "."))
    return None


def main(argv):
    amps = 4.0
    if "--charger-a" in argv:
        i = argv.index("--charger-a")
        amps = float(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) < 2 or argv[0] not in ("company", "ids"):
        sys.exit(__doc__ or "usage: bike-specs.py company <name> | ids <uuid>...")
    if argv[0] == "company":
        name = argv[1].replace("'", "''")
        where = f"id = any((select copilot_bike_ids from companies where name = '{name}')::uuid[])"
    else:
        ids = ",".join(f"'{u}'::uuid" for u in argv[1:] if re.fullmatch(r"[0-9a-f-]{36}", u))
        where = f"id in ({ids})"
    rows = query(f"select id, name, sku, power_wh, weight_kg, range_max_km, charge_time_hours, "
                 f"description from bikes where {where} order by name")

    values = []
    print(f"{'sku':<20} {'Wh':>4} | {'weight':>14} | {'range km':>14} | {'charge h':>14}")
    for r in rows:
        lines = plain(r["description"])
        wh = r["power_wh"]
        w = r["weight_kg"] or labelled(lines, "greutate")
        km = r["range_max_km"] or labelled(lines, "autonomie") or (wh and round(wh / WH_PER_KM / 5) * 5)
        h = r["charge_time_hours"] or (wh and round(wh / (CHARGE_V * amps) * CHARGE_LOSS * 2) / 2)
        src = lambda db, v: f"{v} ({'db' if db else 'new'})" if v is not None else "?"
        print(f"{r['sku']:<20} {wh or '?':>4} | {src(r['weight_kg'], w):>14} | "
              f"{src(r['range_max_km'], km):>14} | {src(r['charge_time_hours'], h):>14}  {r['name'][:50]}")
        sql = lambda v: "null" if v is None else str(v)
        values.append(f"  ('{r['id']}'::uuid, {sql(w)}, {sql(km)}, {sql(h)})")

    print("\n-- review every value against the maker's page before running")
    print("update bikes set weight_kg = v.w, range_max_km = v.r, charge_time_hours = v.c\nfrom (values")
    print(",\n".join(values))
    print(") v(id, w, r, c)\nwhere bikes.id = v.id;")


if __name__ == "__main__":
    main(sys.argv[1:])
