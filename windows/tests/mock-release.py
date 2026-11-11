"""Tiny GitHub-API look-alike for testing scripts/setup.ps1's real download/hash path.

usage: mock-release.py <port> <zip> <sha256-file> [--no-sha]
Serves /repos/test/murmur/releases (JSON) and /dl/<file>. Assets are octet-stream, like real release assets.
"""
import http.server, json, os, sys

port, zip_path, sha_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
with_sha = "--no-sha" not in sys.argv
base = f"http://127.0.0.1:{port}"
files = {"murmur-win-x64.zip": zip_path, "murmur-win-x64.zip.sha256": sha_path}
assets = [{"name": "murmur-win-x64.zip", "size": os.path.getsize(zip_path), "browser_download_url": f"{base}/dl/murmur-win-x64.zip"}]
if with_sha:
    assets.append({"name": "murmur-win-x64.zip.sha256", "size": os.path.getsize(sha_path), "browser_download_url": f"{base}/dl/murmur-win-x64.zip.sha256"})
releases = [{"tag_name": "win-v0.0.0-test", "draft": False, "assets": assets}]


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/repos/test/murmur/releases":
            body, ctype = json.dumps(releases).encode(), "application/json"
        elif path.startswith("/dl/") and path[4:] in files:
            with open(files[path[4:]], "rb") as f:
                body = f.read()
            ctype = "application/octet-stream"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
