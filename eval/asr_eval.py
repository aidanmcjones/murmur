import json, sys, time, os, urllib.request, uuid
sys.path.insert(0, os.path.dirname(__file__)); from wer import wer
data, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
prompt = sys.argv[4] if len(sys.argv) > 4 else ""
def transcribe(path):
    b = uuid.uuid4().hex; body = b""
    for k, v in [("response_format","json"),("temperature","0"),("prompt",prompt)]:
        body += f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode() + open(path,"rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/inference", body, {"Content-Type": f"multipart/form-data; boundary={b}"})
    return " ".join(json.loads(urllib.request.urlopen(req, timeout=120).read())["text"].split())
E = N = 0; lat = []; rows = []
for line in open(os.path.join(data, "set.jsonl")):
    r = json.loads(line); t = time.time(); hyp = transcribe(os.path.join(data, r["id"] + ".wav")); lat.append(time.time()-t)
    e, n = wer(r["asr"], hyp); E += e; N += n; rows.append(dict(id=r["id"], hyp=hyp, ref=r["asr"], e=e, n=n, rtf=lat[-1]/r["dur"]))
json.dump(rows, open(out, "w"), indent=1)
lat.sort(); print(f"WER vs WF-asr {E/N:.3%}  n={len(rows)}  latency p50={lat[len(lat)//2]:.2f}s p90={lat[int(len(lat)*.9)]:.2f}s")
