import json,sys
# Pseudo-ASR file using Wispr Flow's own ASR text, to isolate the cleanup stage.
rows=[json.loads(l) for l in open(sys.argv[1])]
json.dump([dict(id=r["id"],hyp=r["asr"],ms=0) for r in rows], open(sys.argv[2],"w"))
