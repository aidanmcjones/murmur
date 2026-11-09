"""Held-out eval set from Wispr Flow history: excludes ids already in eval/data/set.jsonl."""
import sqlite3, json, os, sys, random
db = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
out, n, old = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.makedirs(out, exist_ok=True)
skip = {json.loads(l)["id"] for l in open(old)}
con = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
rows = con.execute("""select transcriptEntityId, audio, asrText, formattedText, editedText, app, duration, additionalContext, e2eLatency
  from History where audio is not null and status='formatted' and formattedText is not null and asrText is not null
  and duration between 1 and 60""").fetchall()
rows = [r for r in rows if r[0] not in skip]
random.seed(11); random.shuffle(rows)
with open(os.path.join(out, "set.jsonl"), "w") as f:
    for tid, audio, asr, fmt, edited, app, dur, ctx, lat in rows[:n]:
        open(os.path.join(out, f"{tid}.wav"), "wb").write(audio)
        c = json.loads(ctx) if ctx else {}
        tb = (c.get("textbox_contents") or {})
        f.write(json.dumps(dict(id=tid, asr=asr, wf=fmt, edited=(edited or "").strip() or None, app=app, dur=dur, wf_ms=lat,
            before=(tb.get("beforeText") or "")[-400:], after=(tb.get("afterText") or "")[:200])) + "\n")
print(len(rows), "eligible;", min(n, len(rows)), "exported")
