"""End-to-end parity: run the built Murmur binary headless over eval clips; score vs WF formatted output."""
import json, sys, os, subprocess, time
sys.path.insert(0, os.path.dirname(__file__)); from wer import fer
data, binary, out = sys.argv[1:4]
res = []
for line in open(os.path.join(data, "set.jsonl")):
    r = json.loads(line); t = time.time()
    p = subprocess.run([binary, "--transcribe", os.path.join(data, r["id"] + ".wav"), "--bundle-id", r["app"] or "com.google.Chrome"],
                       capture_output=True, text=True, timeout=60)
    res.append(dict(id=r["id"], app=r["app"], hyp=p.stdout.strip(), wf=r["wf"], edited=r["edited"], wall=time.time()-t, err=p.stderr[-2000:]))
E=N=E2=N2=0
for x in res:
    e,n = fer(x["wf"], x["hyp"]); E+=e; N+=n; x["e"]=e/n
    if x["edited"]: e,n = fer(x["edited"], x["hyp"]); E2+=e; N2+=n
w = sorted(x["wall"] for x in res)
json.dump(res, open(out, "w"), indent=1)
print(f"Murmur e2e format-error vs WF output: {E/N:.2%}  vs user-kept text: {E2/max(N2,1):.2%}  | wall p50={w[len(w)//2]:.2f}s p90={w[int(len(w)*.9)]:.2f}s (incl. process start)")
