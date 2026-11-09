"""usage: score_asr.py <data> <eval_dir> asr_*.json ... -> WER vs WF asr, fmt-err (det cleanup) vs WF output, latency."""
import json, sys, os, re
data, evd = sys.argv[1], sys.argv[2]
sys.path.insert(0, evd); from wer import fer, wer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
FILLER = re.compile(r"(?i)(^|\s)(um+|uh+|erm+|hmm+)[,.…]*(?=\s|$)")
def det(t):
    t = FILLER.sub(" ", t); t = re.sub(r"(?i)\b(\w+)( \1\b)+", r"\1", t)
    t = re.sub(r"\s+([,.?!])", r"\1", t); t = re.sub(r"\s{2,}", " ", t).strip(); t = re.sub(r"^[,.\s]+", "", t)
    return t[:1].upper() + t[1:] if t else t
S = {json.loads(l)["id"]: json.loads(l) for l in open(os.path.join(data, "set.jsonl"))}
for f in sys.argv[3:]:
    H = json.load(open(f)); W=N=E=M=0; lat=[]
    for h in H:
        r = S[h["id"]]; e,n = wer(r["asr"], h["hyp"]); W+=e; N+=n
        e,n = fer(r["wf"], det(h["hyp"])); E+=e; M+=n; lat.append(h["ms"])
    lat.sort()
    print(f"{os.path.basename(f):28s} WER {W/N:6.2%}  fmt-err {E/M:6.2%}  p50 {lat[len(lat)//2]:5.0f}ms  p90 {lat[int(len(lat)*.9)]:5.0f}ms")
