"""Export (audio, asrText, formattedText, editedText, app, context) from Wispr Flow's local DB for fidelity eval."""
import sqlite3, json, os, sys, random
db = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
out = sys.argv[1]; n = int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?immutable=1", uri=True)
rows = con.execute("""select transcriptEntityId, audio, asrText, formattedText, editedText, app, duration, additionalContext
  from History where audio is not null and status='formatted' and formattedText is not null and duration between 2 and 60""").fetchall()
random.seed(7); random.shuffle(rows)
with open(os.path.join(out, "set.jsonl"), "w") as f:
    for tid, audio, asr, fmt, edited, app, dur, ctx in rows[:n]:
        open(os.path.join(out, f"{tid}.wav"), "wb").write(audio)
        c = json.loads(ctx) if ctx else {}
        tb = (c.get("textbox_contents") or {})
        f.write(json.dumps(dict(id=tid, asr=asr, wf=fmt, edited=(edited or "").strip() or None, app=app, dur=dur,
            before=(tb.get("beforeText") or "")[-400:], after=(tb.get("afterText") or "")[:200])) + "\n")
print(len(rows), "eligible;", min(n, len(rows)), "exported")
