"""Cleanup latency on llama-server (OpenAI API), app-identical messages. usage: llm_speed.py data port out.json"""
import json, sys, os, time, urllib.request, sqlite3
sys.path.insert(0, os.path.dirname(__file__)); from wer import fer
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
data, port, out = sys.argv[1:4]
SRC = {x["id"]: x["hyp"] for x in json.load(open(sys.argv[4]))} if len(sys.argv) > 4 else None
R = lambda f: open(os.path.join(root, "Sources/Murmur/Resources", f)).read()
PROMPT, FEW, STY = R("cleanup_prompt.txt"), json.loads(R("fewshot.json")), json.loads(R("styles.json"))
db = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
VOCAB = [p for (p,) in sqlite3.connect(f"file:{db}?immutable=1", uri=True).execute("select phrase from Dictionary where isDeleted=0 and replacement is null")]
APPS = {"com.apple.MobileSMS":("Messages","messaging"),"com.tinyspeck.slackmacgap":("Slack","messaging"),"com.microsoft.Outlook":("Outlook","email"),
        "com.microsoft.Word":("Word","email"),"com.apple.Terminal":("Terminal","ai"),"com.anthropic.claudefordesktop":("Claude","ai"),"com.openai.codex":("Codex","ai")}
res = []
for line in open(os.path.join(data, "set.jsonl")):
    r = json.loads(line); name, st = APPS.get(r["app"], ("the active app", "default"))
    sysm = PROMPT.replace("{{APP}}", name).replace("{{STYLE}}", STY[st]).replace("{{VOCAB}}", ", ".join(VOCAB))
    msgs = [{"role":"system","content":sysm}] + [m for a,b in FEW for m in ({"role":"user","content":f"<<<\n{a}\n>>>"},{"role":"assistant","content":b})] + [{"role":"user","content":f"<<<\n{(SRC[r['id']] if SRC else r['asr']).strip()}\n>>>"}]
    body = dict(messages=msgs, temperature=0, max_tokens=1024, cache_prompt=True)
    t = time.time()
    d = json.loads(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", json.dumps(body).encode(), {"content-type":"application/json"}), timeout=60).read())
    ms = (time.time() - t) * 1000; hyp = d["choices"][0]["message"]["content"].strip()
    tm = d.get("timings", {})
    res.append(dict(id=r["id"], raw=(SRC[r["id"]] if SRC else r["asr"]), hyp=hyp, wf=r["wf"], ms=ms, gen=tm.get("predicted_n"), gen_ms=tm.get("predicted_ms"), pp_ms=tm.get("prompt_ms"), acc=tm.get("draft_n_accepted"), drafted=tm.get("draft_n")))
json.dump(res, open(out, "w"), indent=1)
E=N=0
for x in res: e,n = fer(x["wf"], x["hyp"]); E+=e; N+=n
l = sorted(x["ms"] for x in res); tps = sum(x["gen"] or 0 for x in res) / max(sum(x["gen_ms"] or 0 for x in res), 1) * 1000
print(f"port {port}: format-err {E/N:.2%}  p50 {l[len(l)//2]:.0f}ms p90 {l[int(len(l)*.9)]:.0f}ms  gen {tps:.0f} tok/s  prompt p50 {sorted(x['pp_ms'] or 0 for x in res)[40]:.0f}ms")
