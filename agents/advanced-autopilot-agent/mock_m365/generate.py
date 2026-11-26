"""Seeded generator for the mock M365 inbox + calendar (deterministic, relative to "today").

    python -m mock_m365.generate [--out PATH] [--seed N] [--today YYYY-MM-DD]

Same seed + same today -> byte-identical output. Nothing here is hand-written JSON.
"""
from __future__ import annotations

import argparse
import json
import random
from datetime import date, datetime, timedelta, timezone

SEED = 20261126
TZ = timezone(timedelta(hours=8))  # demo user's local zone (AWST)
USER = {"name": "Alex Morgan", "email": "alex.morgan@contoso.example"}

PEOPLE = [
    ("Priya Nair", "priya.nair", "Finance"), ("Tom Becker", "tom.becker", "Engineering"),
    ("Sofia Alvarez", "sofia.alvarez", "Legal"), ("Daniel Kim", "daniel.kim", "Sales"),
    ("Hannah Wright", "hannah.wright", "HR"), ("Marcus Lee", "marcus.lee", "Security"),
    ("Elena Petrova", "elena.petrova", "Product"), ("Jack O'Neill", "jack.oneill", "Operations"),
]
URGENT = [
    ("URGENT: Contract renewal needs your sign-off by {dl}", "Legal needs your signature on the Fabrikam renewal before {dl}. Reply to confirm."),
    ("Production incident INC-{n}: payments API latency", "p95 latency is 4x normal. We need an owner for the mitigation call. Can you join?"),
    ("Action required: Q4 budget variance explanation", "Finance flagged a 12% variance on cloud spend. Please explain by {dl}."),
    ("Security: confirm unusual sign-in on your account", "A sign-in from a new device was detected. Please confirm it was you today."),
]
FYI = [
    ("FYI: Updated parental leave policy", "HR has published the updated policy. No action needed."),
    ("FYI: Sprint {n} demo recording available", "The recording and slides are on the team site."),
    ("FYI: Office closed Friday afternoon for maintenance", "Badge readers will be offline from 1pm."),
    ("FYI: New vendor onboarding checklist", "Procurement's checklist has moved to the wiki."),
    ("FYI: Customer win - Northwind expands to 400 seats", "Great news from Sales; congratulations to the account team."),
    ("FYI: Quarterly all-hands moved to next Thursday", "Calendar invite will follow."),
]
NEWSLETTERS = [
    ("Contoso Weekly Digest", "Top stories: product roadmap highlights, people news, and a recipe swap."),
    ("Azure Updates: what's new this week", "New regions, preview features, and retirement notices."),
    ("The Tech Brief - Daily", "Five links worth reading about AI agents and platform engineering."),
    ("Engineering Guild Newsletter", "Talks, brown-bag sessions and the reading list."),
]
THREADS = [  # subject, bodies - first is the original, rest are replies
    ("Launch readiness review", [
        "Can we confirm the go/no-go criteria for the launch? Draft attached.",
        "Criteria look right to me. Security sign-off still pending.",
        "Security will finish by tomorrow noon; no blockers from my side.",
    ]),
    ("Customer workshop agenda - Adatum", [
        "Proposed agenda for the Adatum workshop below. Thoughts?",
        "Suggest moving the architecture session to the morning.",
    ]),
    ("Lunch & learn topic ideas", [
        "Collecting ideas for next month's lunch & learn.",
        "Vote for 'prompt injection defences'.",
        "Seconded.",
    ]),
]


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def generate(seed: int = SEED, today: date | None = None) -> dict:
    rng = random.Random(seed)
    today = today or datetime.now(TZ).date()
    now = datetime.combine(today, datetime.min.time(), TZ).replace(hour=9, minute=30)
    people = [{"name": n, "email": f"{e}@contoso.example", "dept": d} for n, e, d in PEOPLE]
    msgs: list[dict] = []

    def add(subject, body, sender, received, importance, category, thread=None, is_read=None):
        mid = f"AAMk-{seed % 10000:04d}-{len(msgs) + 1:03d}"
        read = (rng.random() < 0.3) if is_read is None else is_read
        msgs.append({
            "id": mid, "subject": subject, "from": {"name": sender["name"], "email": sender["email"]},
            "receivedDateTime": _iso(received), "importance": importance, "category": category,
            "conversationId": thread or f"conv-{mid}", "isRead": read,
            "bodyPreview": body[:120], "body": body,
            "webLink": f"https://outlook.office.com/mail/id/{mid}",
        })

    def when(max_hours_ago: float, min_hours_ago: float = 0.2) -> datetime:
        return now - timedelta(minutes=int(rng.uniform(min_hours_ago, max_hours_ago) * 60))

    dl = (today + timedelta(days=1)).strftime("%A")
    for tpl, body in rng.sample(URGENT, 4):
        add(tpl.format(dl=dl, n=rng.randint(1000, 9999)), body.format(dl=dl), rng.choice(people),
            when(20), "high", "urgent", is_read=False)
    for tpl, body in rng.sample(FYI, 6):
        add(tpl.format(n=rng.randint(20, 40)), body, rng.choice(people), when(70), "normal", "fyi")
    for subj, body in NEWSLETTERS:
        add(subj, body, {"name": "Contoso Communications", "email": "news@contoso.example"},
            when(60), "low", "newsletter")
    for subj, bodies in THREADS:
        conv = f"conv-thread-{subj.lower().replace(' ', '-')}"
        t = when(48, 10)
        starter = rng.choice(people)
        for i, body in enumerate(bodies):
            sender = starter if i == 0 else rng.choice([p for p in people if p is not starter])
            if i:
                t = min(t + timedelta(minutes=rng.randint(25, 240)), now - timedelta(minutes=5))
            add(subj if i == 0 else f"RE: {subj}", body, sender, t, "normal", "thread", thread=conv)
    while len(msgs) < 25:  # pad with routine mail
        add(f"Quick question about {rng.choice(['the roadmap', 'access request', 'timesheets', 'the offsite'])}",
            "Do you have a minute this week?", rng.choice(people), when(72), "normal", "fyi")
    msgs.sort(key=lambda m: m["receivedDateTime"], reverse=True)

    def ev(i, subject, day, start_h, start_m, mins, organizer, location, attendees):
        s = datetime.combine(today + timedelta(days=day), datetime.min.time(), TZ).replace(hour=start_h, minute=start_m)
        eid = f"AAEv-{seed % 10000:04d}-{i:03d}"
        return {"id": eid, "subject": subject, "start": _iso(s), "end": _iso(s + timedelta(minutes=mins)),
                "location": location, "organizer": organizer["name"],
                "attendees": [a["name"] for a in attendees], "isOnlineMeeting": location == "Microsoft Teams",
                "webLink": f"https://outlook.office.com/calendar/item/{eid}"}

    p = rng.sample(people, 6)
    events = [
        ev(1, "Team standup", 0, 9, 30, 15, p[0], "Microsoft Teams", p[:3]),
        ev(2, "Launch readiness review", 0, 11, 0, 60, p[1], "Meeting Room Fremantle", p[1:4]),
        ev(3, "Customer call - Northwind expansion", 0, 11, 30, 45, p[2], "Microsoft Teams", p[2:5]),  # overlaps #2
        ev(4, "1:1 with Priya Nair", 0, 15, 0, 30, people[0], "Microsoft Teams", [people[0]]),
        ev(5, "Budget variance working session", 1, 10, 0, 60, p[3], "Microsoft Teams", p[3:6]),
        ev(6, "Adatum workshop prep", 1, 14, 0, 45, p[4], "Meeting Room Swan", p[4:6]),
    ]
    return {"generated_for": today.isoformat(), "seed": seed, "user": USER, "messages": msgs, "events": events}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="-")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--today", default=None)
    a = ap.parse_args()
    data = generate(a.seed, date.fromisoformat(a.today) if a.today else None)
    text = json.dumps(data, indent=2)
    if a.out == "-":
        print(text)
    else:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
