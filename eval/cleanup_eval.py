"""usage: cleanup_eval.py <data> <asr_json> <murmur_src_root> <port> <out.json>
Scores, vs Wispr Flow formatted output: deterministic cleanup, LLM cleanup, and gated (LLM only when needed)."""
import json, sys, os, re, time, urllib.request, sqlite3
data, asr_json, root, port, out = sys.argv[1:6]
sys.path.insert(0, os.path.join(root, "eval")); from wer import fer, wer
R = lambda f: open(os.path.join(root, "Sources/Murmur/Resources", f)).read()
PROMPT, FEW, STY = R("cleanup_prompt.txt"), json.loads(R("fewshot.json")), json.loads(R("styles.json"))
VOCAB = [e["phrase"] for e in json.load(open(os.path.expanduser("~/Library/Application Support/Murmur/dictionary.json"))) if not e.get("replacement")]
APPS = {"com.apple.MobileSMS":("Messages","messaging"),"com.tinyspeck.slackmacgap":("Slack","messaging"),"com.microsoft.Outlook":("Outlook","email"),
        "com.microsoft.Word":("Word","email"),"com.apple.Terminal":("Terminal","ai"),"com.anthropic.claudefordesktop":("Claude","ai"),"com.openai.codex":("Codex","ai")}
FILLER = re.compile(r"(?i)(^|\s)(um+|uh+|erm+|hmm+|uh-huh)[,.…]*(?=\s|$)")
def det(t):
    t = FILLER.sub(" ", t)
    t = re.sub(r"(?i)\b(\w+)( \1\b)+", r"\1", t)          # stutter repeats: "the the"
    t = re.sub(r"\s+([,.?!])", r"\1", t); t = re.sub(r"\s{2,}", " ", t).strip()
    t = re.sub(r"^[,.\s]+", "", t)
    if t and t[0].islower(): t = t[0].upper() + t[1:]
    return t
NEED = re.compile(r"(?i)\b(um+|uh+|erm|hmm|you know|i mean|actually|no wait|wait no|scratch that|sorry|or rather|rather|"
                  r"comma|period|full stop|question mark|exclamation (mark|point)|colon|semicolon|new line|newline|new paragraph|"
                  r"open quote|close quote|end quote|slash|dash|bullet|number one|first(ly)?|second(ly)?|third(ly)?|"
                  r"zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|hundred|thousand|percent|dollars?)\b"
                  r"|\b(\w+) \3\b")
def need_llm(raw): return bool(NEED.search(raw)) or len(raw.split()) > 60
def llm(raw, app):
    name, st = APPS.get(app, ("the active app", "default"))
    sysm = PROMPT.replace("{{APP}}", name).replace("{{STYLE}}", STY[st]).replace("{{VOCAB}}", ", ".join(VOCAB))
    msgs = [{"role":"system","content":sysm}] + [m for a,b in FEW for m in ({"role":"user","content":f"<<<\n{a}\n>>>"},{"role":"assistant","content":b})] + [{"role":"user","content":f"<<<\n{raw}\n>>>"}]
    t = time.time()
    d = json.loads(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
        json.dumps(dict(messages=msgs, temperature=0, max_tokens=1024, cache_prompt=True)).encode(), {"content-type":"application/json"}), timeout=60).read())
    return d["choices"][0]["message"]["content"].strip().replace("<<<","").replace(">>>","").strip(), (time.time()-t)*1000
H = {x["id"]: x for x in json.load(open(asr_json))}
res = []
for line in open(os.path.join(data, "set.jsonl")):
    r = json.loads(line); h = H.get(r["id"])
    if not h: continue
    raw = h["hyp"].strip()
    l, lms = llm(raw, r["app"]) if raw else ("", 0)
    res.append(dict(id=r["id"], app=r["app"], wfasr=r["asr"], wf=r["wf"], raw=raw, det=det(raw), llm=l, llm_ms=lms, gate=need_llm(raw), asr_ms=h["ms"], wf_ms=r.get("wf_ms")))
json.dump(res, open(out, "w"), indent=1)
def F(key):
    E=N=0
    for x in res:
        hyp = x[key] if key != "gated" else (x["llm"] if x["gate"] else x["det"])
        e,n = fer(x["wf"], hyp); E+=e; N+=n
    return E/N
W=N=0
for x in res: e,n = wer(x["wfasr"], x["raw"]); W+=e; N+=n
g = sum(x["gate"] for x in res)
lat = sorted(x["llm_ms"] for x in res)
print(f"{os.path.basename(asr_json)}: n={len(res)} WER-vs-WF-asr={W/N:.2%} | fmt-err raw={F('raw'):.2%} det={F('det'):.2%} llm={F('llm'):.2%} gated={F('gated'):.2%} (LLM on {g}/{len(res)}) | llm p50={lat[len(lat)//2]:.0f} p90={lat[int(len(lat)*.9)]:.0f}ms")
