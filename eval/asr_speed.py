"""ASR latency/accuracy sweep over whisper-server request params. usage: asr_speed.py data port '<json params>'"""
import json, sys, os, time, urllib.request, uuid, wave
sys.path.insert(0, os.path.dirname(__file__)); from wer import wer
data, port, extra = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
def post(path, fields):
    b = uuid.uuid4().hex; body = b""
    for k, v in fields.items():
        body += f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode() + open(path,"rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/inference", body, {"Content-Type": f"multipart/form-data; boundary={b}"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())
E=N=0; lat=[]
for line in open(os.path.join(data, "set.jsonl")):
    r = json.loads(line); p = os.path.join(data, r["id"] + ".wav")
    secs = wave.open(p).getnframes() / 16000
    f = {"response_format": "verbose_json", "temperature": "0"}
    for k, v in extra.items():
        f[k] = str(min(1500, int(secs * 50) + v)) if k == "audio_ctx_pad" else str(v)
    if "audio_ctx_pad" in f: f["audio_ctx"] = f.pop("audio_ctx_pad")
    t = time.time(); j = post(p, f); lat.append((time.time() - t, secs))
    e, n = wer(r["asr"], " ".join(j["text"].split())); E += e; N += n
l = sorted(x for x, _ in lat)
short = sorted(x for x, s in lat if s < 10)
print(f"{json.dumps(extra):45s} WER {E/N:6.2%}  p50 {l[len(l)//2]*1000:4.0f}ms  p90 {l[int(len(l)*.9)]*1000:4.0f}ms  short(<10s) p50 {short[len(short)//2]*1000:4.0f}ms")
