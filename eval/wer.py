import re
_num = {"zero":"0","one":"1","two":"2","three":"3","four":"4","five":"5","six":"6","seven":"7","eight":"8","nine":"9","ten":"10"}
def norm(s):
    s = (s or "").lower().replace("’","'")
    s = re.sub(r"[^\w\s'%]", " ", s)
    return [_num.get(w, w) for w in s.split()]
def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h)+1))
    for i in range(1, len(r)+1):
        prev, d[0] = d[0], i
        for j in range(1, len(h)+1):
            cur = min(d[j]+1, d[j-1]+1, prev + (r[i-1] != h[j-1]))
            prev, d[j] = d[j], cur
    return d[len(h)], max(len(r), 1)

def ftoks(s):
    """Formatting-sensitive tokens: case-sensitive words + punctuation + line breaks."""
    s = re.sub(r"</li>\s*", "\n", s or ""); s = re.sub(r"<li>", "- ", s); s = re.sub(r"</?(ul|ol)>", "\n", s)
    s = re.sub(r"\n{2,}", " ¶ ", s.strip()); s = s.replace("\n", " ↵ ")
    return re.findall(r"[\w'’%$-]+|[^\w\s]|¶|↵", s)
def ed(a, b):
    d = list(range(len(b)+1))
    for i in range(1, len(a)+1):
        prev, d[0] = d[0], i
        for j in range(1, len(b)+1):
            cur = min(d[j]+1, d[j-1]+1, prev + (a[i-1] != b[j-1])); prev, d[j] = d[j], cur
    return d[len(b)]
def fer(ref, hyp):
    r = ftoks(ref); return ed(r, ftoks(hyp)), max(len(r), 1)
