"""Seed test donation entries for the NF-003 paging tests (dev databases only).

Goes through the LOCAL backend's API (uvicorn on localhost), so every entry
passes the same validation as a real donation. Nothing is written directly
to the database.

    # 1. see the validated reports you can donate to
    python scripts/seed_test_donations.py --list-reports

    # 2. seed: report_id:how_many, comma separated
    python scripts/seed_test_donations.py --plan 12:30,15:15,20:5

Accounts are asked for at the prompt (nothing is saved):
  donor  (required)  makes the donations, cancels a few
  CSWS   (optional)  receives one entry fully and one partly
  CMO    (optional)  puts the fully received entry On Hold
Leave CSWS / CMO empty to skip those steps.

Safety:
- only talks to localhost / 127.0.0.1;
- shows the database host from backend/app/.env and asks you to type SEED;
- use a Neon BRANCH (or another dev database), never the one Render uses.
Side effects: in-app notifications for the donor and CSWS users in that
database. No emails or SMS are sent for donations.
"""
import argparse
import getpass
import os
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

import httpx

MANILA = timezone(timedelta(hours=8))
LOCAL_HOSTS = {"localhost", "127.0.0.1"}


def die(msg: str) -> None:
    print(f"\nSTOP: {msg}")
    sys.exit(1)


def database_host() -> str:
    """Host part of DATABASE_URL (never the password): the terminal's
    $env:DATABASE_URL first (it wins over .env, as in the backend), else
    backend/app/.env."""
    if os.getenv("DATABASE_URL"):
        return urlparse(os.environ["DATABASE_URL"]).hostname or "(could not read host)"
    env = Path(__file__).resolve().parent.parent / ".env"
    if not env.exists():
        return "(no backend/app/.env found)"
    for line in env.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("DATABASE_URL"):
            url = line.split("=", 1)[1].strip().strip('"').strip("'")
            return urlparse(url).hostname or "(could not read host)"
    return "(DATABASE_URL not in .env)"


def check(r: httpx.Response, what: str) -> dict:
    if r.status_code >= 300:
        try:
            detail = r.json().get("detail")
        except Exception:
            detail = r.text[:200]
        raise RuntimeError(f"{what} -> {r.status_code}: {detail}")
    return r.json() if r.content else {}


def login(client: httpx.Client, role: str, required: bool):
    email = input(f"{role} email{'' if required else ' (Enter to skip)'}: ").strip()
    if not email:
        if required:
            die(f"a {role} account is required")
        return None
    password = getpass.getpass(f"{role} password: ")
    data = check(client.post("/token", data={"username": email, "password": password}),
                 f"log in as {role}")
    return {"Authorization": f"Bearer {data['access_token']}"}


def next_pickup_slot() -> str:
    """A weekday at 10:00 Philippine time, at least a day ahead."""
    d = datetime.now(MANILA) + timedelta(days=1)
    while d.isoweekday() > 5:
        d += timedelta(days=1)
    return d.replace(hour=10, minute=0, second=0, microsecond=0).isoformat()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", default="http://localhost:8000")
    ap.add_argument("--list-reports", action="store_true")
    ap.add_argument("--plan", help="report_id:count,... e.g. 12:30,15:15,20:5")
    ap.add_argument("--guests", type=int, default=3, help="guest donations on the first report")
    ap.add_argument("--cancel", type=int, default=3, help="donor entries to cancel")
    ap.add_argument("--door-every", type=int, default=6, help="every Nth donation is Door to Door")
    ap.add_argument("--receive", type=int, default=1,
                    help="entries CSWS receives fully (besides 1 partly received)")
    ap.add_argument("--acknowledge", type=int, default=0,
                    help="of the received ones, how many the CMO acknowledges (History)")
    ap.add_argument("--hold", type=int, default=1,
                    help="of the received ones, how many the CMO puts On Hold")
    args = ap.parse_args()

    if urlparse(args.api).hostname not in LOCAL_HOSTS:
        die(f"--api must be your local backend (localhost), not {args.api}")

    client = httpx.Client(base_url=args.api.rstrip("/"), timeout=30)
    try:
        client.get("/health").raise_for_status()
    except Exception as e:
        die(f"the local backend is not answering at {args.api} ({e}). Start uvicorn first.")

    reports = {r["id"]: r for r in check(client.get("/lookups"), "lookups")["validated_reports"]}
    if args.list_reports:
        print("\nValidated reports (id  barangay  label):")
        for rid, r in sorted(reports.items()):
            print(f"  {rid:>5}  {r['barangay']:<22} {r['name']}")
        return
    if not args.plan:
        die("give --plan report_id:count,...  (see --list-reports)")

    plan = []
    for part in args.plan.split(","):
        rid, n = (int(x) for x in part.split(":"))
        if rid not in reports:
            die(f"report {rid} is not a validated report (see --list-reports)")
        plan.append((rid, n))

    print(f"\nLocal backend: {args.api}")
    print(f"Database host (set DATABASE_URL in this terminal too): {database_host()}")
    print("This must be a Neon BRANCH or another dev database, never the one Render uses.")
    for rid, n in plan:
        print(f"  {n:>3} entries -> report {rid} ({reports[rid]['barangay']})")
    if input("Type SEED to continue: ").strip() != "SEED":
        die("cancelled, nothing was written")

    donor = login(client, "Donor", required=True)
    csws = login(client, "CSWS Main Office", required=False)
    cmo = login(client, "CMO Representative", required=False)

    items = check(client.get("/lookups", headers=donor), "lookups")["items"][:6]
    if not items:
        die("no active items in this database")
    rnd = random.Random(2026)
    made, failures, k = [], 0, 0

    for rid, n in plan:
        for _ in range(n):
            k += 1
            lines = [{"item_id": rnd.choice(items)["id"], "packaging": "Box",
                      "quantity": rnd.randint(1, 20)} for _ in range(rnd.randint(1, 3))]
            body = {"report_id": rid, "handover_method": "Drop Off", "items": lines}
            if args.door_every and k % args.door_every == 0:
                body.update(handover_method="Door to Door",
                            pickup_address="1 Test St, Mandaue City",
                            preferred_pickup_at=next_pickup_slot())
            try:
                try:
                    b = check(client.post("/donations/batch", headers=donor, json=body), "donate")
                except RuntimeError as e:
                    if body["handover_method"] != "Door to Door":
                        raise
                    print(f"  Door to Door refused ({e}); using Drop Off")
                    body = {"report_id": rid, "handover_method": "Drop Off", "items": lines}
                    b = check(client.post("/donations/batch", headers=donor, json=body), "donate")
                made.append((b["batch_reference"], rid, len(lines)))
                failures = 0
                print(f"  {len(made):>3}. {b['batch_reference']}  report {rid}  "
                      f"{len(lines)} item(s)  {body['handover_method']}")
            except RuntimeError as e:
                failures += 1
                print(f"  failed: {e}")
                if failures >= 5:
                    die("5 failures in a row, stopping")

    first = plan[0][0]
    guests_made = 0
    names = ["Ana", "Ben", "Carla", "Dino", "Ella", "Fe", "Gil", "Hana", "Ivy", "Jun"]
    for g in range(args.guests):
        body = {"report_id": first, "handover_method": "Drop Off",
                "items": [{"item_id": items[0]["id"], "packaging": "Box", "quantity": 2 + g}],
                # Names may only hold letters, spaces, hyphens, apostrophes, periods.
                "guest_donor": {"full_name": f"Seed Guest {names[g % len(names)]}",
                                "contact_number": f"0917{rnd.randint(1000000, 9999999)}",
                                "consent": True}}
        try:
            b = check(client.post("/donations/batch", json=body), "guest donate")
            guests_made += 1
            print(f"  guest  {b['batch_reference']}  report {first}")
        except RuntimeError as e:
            print(f"  guest failed: {e}")

    donor_refs = [ref for ref, _, _ in made]
    for ref in donor_refs[:args.cancel]:
        try:
            check(client.post(f"/donations/entries/{ref}/cancel", headers=donor,
                              json={"reason": "I changed my mind"}), "cancel")
            print(f"  cancelled {ref}")
        except RuntimeError as e:
            print(f"  cancel failed: {e}")

    received = []
    if csws:
        rest = [ref for ref, _, _ in made[args.cancel:]]
        multi = [ref for ref, _, n in made[args.cancel:] if n >= 2]
        partly_ref = multi[0] if multi else None
        full = [ref for ref in rest if ref != partly_ref][:args.receive]
        for ref, partly in [(partly_ref, True)] + [(r, False) for r in full]:
            if not ref:
                continue
            try:
                entry = check(client.get("/donations/records", headers=csws,
                                         params={"q": ref, "include_closed": "true"}), "find entry")[0]
                lines = entry["items"][:1] if partly else entry["items"]
                check(client.post(f"/donations/entries/{ref}/receive", headers=csws, json={
                    "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]}
                              for i in lines]}), "receive")
                print(f"  received {'1 item of' if partly else 'all of'} {ref}")
                if not partly:
                    received.append(ref)
            except (RuntimeError, IndexError) as e:
                print(f"  receive failed for {ref}: {e}")

    if cmo and received:
        decisions = ([(r, "Acknowledged", None) for r in received[:args.acknowledge]]
                     + [(r, "On Hold", "Seed: waiting for papers")
                        for r in received[args.acknowledge:args.acknowledge + args.hold]])
        for ref, decision, notes in decisions:
            try:
                check(client.post(f"/cmo/entries/{ref}/decide", headers=cmo,
                                  json={"status": decision, "notes": notes}), decision)
                print(f"  {decision:<12} {ref}")
            except RuntimeError as e:
                print(f"  {decision} failed for {ref}: {e}")

    print(f"\nDone: {len(made)} donor entries + {guests_made} guest entries.")
    print("Check: Admin -> Records -> Donations should page 20 at a time.")


if __name__ == "__main__":
    main()
