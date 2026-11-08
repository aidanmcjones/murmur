import json, sys, os, time, urllib.request, sqlite3, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(__file__)); from wer import fer
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
data, model, src, out = sys.argv[1:5]   # src: 'wfasr' (WF raw transcript) or path to asr_*.json (our ASR)
PROMPT = open(os.path.join(root, "Sources/Murmur/Resources/cleanup_prompt.txt")).read()
FEW = json.load(open(os.path.join(root, "Sources/Murmur/Resources/fewshot.json")))
STYLES = json.load(open(os.path.join(root, "Sources/Murmur/Resources/styles.json")))
APPS = {"com.apple.MobileSMS":("Messages","messaging"),"com.tinyspeck.slackmacgap":("Slack","messaging"),"com.microsoft.Outlook":("Outlook","email"),
        "com.microsoft.Word":("Word","email"),"com.apple.Terminal":("Terminal","ai"),"com.anthropic.claudefordesktop":("Claude","ai"),
        "com.openai.codex":("Codex","ai"),"com.google.Chrome":("Chrome","default")}
db = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
VOCAB = [p for (p,) in sqlite3.connect(f"file:{db}?immutable=1", uri=True).execute("select phrase from Dictionary where isDeleted=0 and replacement is null")]
ours = {r["id"]: r["hyp"] for r in json.load(open(src))} if src != "wfasr" else None
from wer import wer as _wer
from wer import norm
def _lcs(a, b):
    d = [0] * (len(b) + 1)
    for x in a:
        p = 0
        for j, y in enumerate(b, 1): t = d[j]; d[j] = p + 1 if x == y else max(d[j], d[j-1]); p = t
    return d[-1]
def guard(raw, hyp):
    r, h = norm(raw), norm(hyp); novel = (len(h) - _lcs(r, h)) / max(len(h), 1)
    return hyp if (novel <= 0.2 and len(h) >= 0.3 * len(r) and len(hyp.split()) <= 1.5 * len(raw.split()) + 6) else raw
def cont(before, text):
    b = before.rstrip(" ")
    if b and b[-1] not in ".!?:\n" and text[:1].isupper() and not text.split()[0].isupper() and text.split()[0] not in ("I","I'm","I'll","I've","I'd"):
        text = text[0].lower() + text[1:]
    return text
def llm(system, user):
    if model.startswith("claude"):
        body = dict(model=model, max_tokens=2048, system=system, messages=[{"role":"user","content":user}], temperature=0)
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(),
              {"content-type":"application/json","x-api-key":os.environ["ANTHROPIC_API_KEY"],"anthropic-version":"2023-06-01"})
        return json.loads(urllib.request.urlopen(req, timeout=60).read())["content"][0]["text"]
    body = dict(model=model, stream=False, think=False, keep_alive="30m", options=dict(temperature=0, num_ctx=4096),
                messages=[{"role":"system","content":system}] + [m for a,b in FEW for m in ({"role":"user","content":f"<<<\n{a}\n>>>"},{"role":"assistant","content":b})] + [{"role":"user","content":user}])
    req = urllib.request.Request("http://127.0.0.1:11434/api/chat", json.dumps(body).encode(), {"content-type":"application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())["message"]["content"]
def run(r):
    name, style = APPS.get(r["app"], ("the active app", "default"))
    system = PROMPT.replace("{{APP}}", name).replace("{{STYLE}}", STYLES[style]).replace("{{VOCAB}}", ", ".join(VOCAB))
    raw = ours[r["id"]] if ours else r["asr"]
    user = f"<<<\n{raw.strip()}\n>>>"
    t = time.time()
    try: hyp = llm(system, user).strip()
    except Exception as ex: hyp = raw; print("ERR", r["id"][:8], ex)
    pre = hyp; hyp = guard(raw, hyp)
    return dict(id=r["id"], app=r["app"], raw=raw, pre=pre, hyp=hyp, wf=r["wf"], edited=r["edited"], lat=time.time()-t)
rows = [json.loads(l) for l in open(os.path.join(data, "set.jsonl"))]
with cf.ThreadPoolExecutor(int(os.environ.get("PAR", "1"))) as ex: res = list(ex.map(run, rows))
def score(key):
    E=N=0
    for x in res: e,n = fer(x["wf"], x[key]); E+=e; N+=n; x["e_"+key]=e/n
    return E/N
b, m = score("raw"), score("hyp")
lat = sorted(x["lat"] for x in res)
json.dump(res, open(out, "w"), indent=1)
print(f"{model} src={os.path.basename(src)}  format-error vs WF: raw={b:.2%}  ours={m:.2%}  | LLM p50={lat[len(lat)//2]:.2f}s p90={lat[int(len(lat)*.9)]:.2f}s")
