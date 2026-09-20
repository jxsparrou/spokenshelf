import json
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = ROOT / "transport.py"


class FakeHandler(BaseHTTPRequestHandler):
    payload = b"0123456789" * 100
    requests = []
    redirect_url = ""

    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.handle_request()

    def do_GET(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request()

    def handle_request(self):
        type(self).requests.append({
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "range": self.headers.get("Range", ""),
        })
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", type(self).redirect_url)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/huge":
            self.send_response(200)
            self.send_header("Content-Length", str(8 * 1024**3 + 1))
            self.end_headers()
            return
        if self.path == "/bad-range":
            self.send_response(206)
            self.send_header("Content-Range", "bytes 10-5/100")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/short-range":
            start = int(self.headers.get("Range", "bytes=0-").removeprefix("bytes=").split("-", 1)[0])
            body = b"x" * 10
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{start + 9}/1000")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        body = type(self).payload
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            start = int(range_header.removeprefix("bytes=").split("-", 1)[0])
            body = body[start:]
            status = 206
            self.send_response(status)
            self.send_header("Content-Range", f"bytes {start}-{len(type(self).payload) - 1}/{len(type(self).payload)}")
        else:
            self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"test"')
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server:
    def __enter__(self):
        FakeHandler.requests = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def run_mode(mode, config):
    return subprocess.run(
        [sys.executable, str(TRANSPORT), mode],
        input=(json.dumps(config) + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
        check=False,
    )


class TransportTests(unittest.TestCase):
    def test_bounded_request_and_authorization(self):
        with Server() as server:
            result = run_mode("request", {
                "server": server.url,
                "url": server.url + "/data",
                "token": "secret-token",
                "method": "GET",
                "maxResponseBytes": 2048,
            })
        self.assertEqual(result.returncode, 0)
        body, status = result.stdout.rsplit(b"\n", 1)
        self.assertEqual(status, b"200")
        self.assertEqual(body, FakeHandler.payload)
        self.assertEqual(FakeHandler.requests[0]["authorization"], "Bearer secret-token")
        self.assertNotIn(b"secret-token", result.stderr)

    def test_oversized_response_is_not_emitted(self):
        with Server() as server:
            result = run_mode("request", {
                "server": server.url,
                "url": server.url + "/data",
                "method": "GET",
                "maxResponseBytes": 100,
            })
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(len(result.stdout), 200)
        self.assertTrue(result.stdout.endswith(b"\n0"))

    def test_proxy_hides_token_and_forwards_ranges(self):
        with Server() as server:
            process = subprocess.Popen(
                [sys.executable, str(TRANSPORT), "proxy"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                process.stdin.write((json.dumps({"server": server.url, "token": "secret-token"}) + "\n").encode())
                process.stdin.flush()
                ready = json.loads(process.stdout.readline())
                local = f"http://127.0.0.1:{ready['port']}/{ready['capability']}/media?url="
                local += urllib.parse.quote(server.url + "/audio", safe="")
                self.assertNotIn("secret-token", local)
                request = urllib.request.Request(local, headers={"Range": "bytes=10-"})
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.read(), FakeHandler.payload[10:])
                self.assertEqual(FakeHandler.requests[-1]["authorization"], "Bearer secret-token")
                self.assertEqual(FakeHandler.requests[-1]["range"], "bytes=10-")
            finally:
                process.stdin.close()
                process.wait(timeout=5)
                self.assertNotIn(b"secret-token", process.stderr.read())
                process.stdout.close()
                process.stderr.close()

    def test_proxy_rejects_cross_origin_redirect(self):
        with Server() as first, Server() as second:
            FakeHandler.redirect_url = second.url + "/audio"
            process = subprocess.Popen(
                [sys.executable, str(TRANSPORT), "proxy"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                process.stdin.write((json.dumps({"server": first.url, "token": "secret-token"}) + "\n").encode())
                process.stdin.flush()
                ready = json.loads(process.stdout.readline())
                local = f"http://127.0.0.1:{ready['port']}/{ready['capability']}/media?url="
                local += urllib.parse.quote(first.url + "/redirect", safe="")
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    urllib.request.urlopen(local, timeout=5)
                raised.exception.close()
            finally:
                process.stdin.close()
                process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()
            second_requests = [entry for entry in FakeHandler.requests if entry["path"] == "/audio"]
            self.assertEqual(second_requests, [])

    def test_proxy_rejects_oversized_media(self):
        with Server() as server:
            process = subprocess.Popen(
                [sys.executable, str(TRANSPORT), "proxy"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                process.stdin.write((json.dumps({"server": server.url, "token": "secret-token"}) + "\n").encode())
                process.stdin.flush()
                ready = json.loads(process.stdout.readline())
                local = f"http://127.0.0.1:{ready['port']}/{ready['capability']}/media?url="
                local += urllib.parse.quote(server.url + "/huge", safe="")
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    urllib.request.urlopen(local, timeout=5)
                self.assertEqual(raised.exception.code, 502)
                raised.exception.close()
            finally:
                process.stdin.close()
                process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()

    def test_proxy_rejects_malformed_range(self):
        with Server() as server:
            process = subprocess.Popen(
                [sys.executable, str(TRANSPORT), "proxy"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                process.stdin.write((json.dumps({"server": server.url, "token": "secret-token"}) + "\n").encode())
                process.stdin.flush()
                ready = json.loads(process.stdout.readline())
                local = f"http://127.0.0.1:{ready['port']}/{ready['capability']}/media?url="
                local += urllib.parse.quote(server.url + "/bad-range", safe="")
                request = urllib.request.Request(local, headers={"Range": "bytes=10-"})
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(raised.exception.code, 502)
                raised.exception.close()
            finally:
                process.stdin.close()
                process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()

    def test_server_path_prefix_is_enforced(self):
        with Server() as server:
            allowed = run_mode("request", {
                "server": server.url + "/base",
                "url": "/data",
                "method": "GET",
                "maxResponseBytes": 2048,
            })
            rejected = run_mode("request", {
                "server": server.url + "/base",
                "url": server.url + "/other/data",
                "token": "secret-token",
                "method": "GET",
                "maxResponseBytes": 2048,
            })
        self.assertEqual(allowed.returncode, 0)
        self.assertEqual(FakeHandler.requests[-1]["path"], "/base/data")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse(any(entry["path"] == "/other/data" for entry in FakeHandler.requests))

    def test_download_quota_and_delete(self):
        with Server() as server, tempfile.TemporaryDirectory() as temporary:
            downloads_root = Path(temporary) / "downloads"
            book_root = downloads_root / "scope" / "book"
            destination = book_root / "0.audio"
            result = run_mode("download", {
                "server": server.url,
                "url": server.url + "/audio",
                "token": "secret-token",
                "downloadsRoot": str(downloads_root),
                "bookRoot": str(book_root),
                "destination": str(destination),
                "trackLimit": 100,
                "bookLimit": 200,
            })
            self.assertNotEqual(result.returncode, 0)
            part = book_root / "0.audio.part"
            self.assertFalse(part.exists())
            book_root.mkdir(parents=True, exist_ok=True)
            (book_root / "existing.audio").write_bytes(b"x" * 150)
            result = run_mode("download", {
                "server": server.url,
                "url": server.url + "/audio",
                "downloadsRoot": str(downloads_root),
                "bookRoot": str(book_root),
                "destination": str(destination),
                "trackLimit": 2000,
                "bookLimit": 1100,
            })
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())
            result = run_mode("delete", {
                "downloadsRoot": str(downloads_root),
                "bookRoot": str(book_root),
                "protectedPaths": [],
            })
            self.assertEqual(result.returncode, 0)
            self.assertFalse(book_root.exists())

    def test_existing_download_and_symlink_are_rejected(self):
        with Server() as server, tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            downloads_root = base / "downloads"
            book_root = downloads_root / "scope" / "book"
            book_root.mkdir(parents=True)
            destination = book_root / "0.audio"
            destination.write_bytes(b"x" * 101)
            result = run_mode("download", {
                "server": server.url,
                "url": server.url + "/audio",
                "downloadsRoot": str(downloads_root),
                "bookRoot": str(book_root),
                "destination": str(destination),
                "trackLimit": 100,
                "bookLimit": 200,
            })
            self.assertNotEqual(result.returncode, 0)

            outside = base / "outside"
            outside.mkdir()
            linked_root = base / "linked-downloads"
            linked_root.symlink_to(outside, target_is_directory=True)
            result = run_mode("download", {
                "server": server.url,
                "url": server.url + "/audio",
                "downloadsRoot": str(linked_root),
                "bookRoot": str(linked_root / "scope" / "book"),
                "destination": str(linked_root / "scope" / "book" / "0.audio"),
            })
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((outside / "scope").exists())

    def test_incomplete_resume_is_not_completed(self):
        with Server() as server, tempfile.TemporaryDirectory() as temporary:
            downloads_root = Path(temporary) / "downloads"
            book_root = downloads_root / "scope" / "book"
            book_root.mkdir(parents=True)
            destination = book_root / "0.audio"
            part = book_root / "0.audio.part"
            part.write_bytes(b"start")
            result = run_mode("download", {
                "server": server.url,
                "url": server.url + "/short-range",
                "downloadsRoot": str(downloads_root),
                "bookRoot": str(book_root),
                "destination": str(destination),
                "trackLimit": 2000,
                "bookLimit": 2000,
            })
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())
            self.assertEqual(part.stat().st_size, 15)

    def test_state_init_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            outside = base / "outside"
            outside.mkdir()
            state = base / "state"
            state.symlink_to(outside, target_is_directory=True)
            result = run_mode("init", {"stateRoot": str(state)})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
