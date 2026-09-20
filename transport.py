#!/usr/bin/env python3
"""Bounded authenticated transport for SpokenShelf."""

from __future__ import annotations

import http.client
import http.server
import json
import os
import re
import secrets
import ssl
import stat
import sys
import threading
import time
import fcntl
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit


CONFIG_LIMIT = 1024 * 1024
CHUNK_SIZE = 64 * 1024
MAX_REDIRECTS = 5
MAX_MEDIA_BYTES = 8 * 1024**3
MAX_MEDIA_SECONDS = 24 * 60 * 60
ALLOWED_RESPONSE_HEADERS = {
    "accept-ranges",
    "cache-control",
    "content-length",
    "content-range",
    "content-type",
    "etag",
    "expires",
    "last-modified",
}
REDIRECT_STATUSES = {301, 302, 303, 307, 308}
RANGE_RE = re.compile(r"bytes=(?:\d+-\d*|-\d+)$")
CONTENT_RANGE_RE = re.compile(r"bytes (\d+)-(\d+)/(\d+|\*)")


class TransportError(Exception):
    pass


def read_config() -> dict:
    raw = sys.stdin.buffer.readline(CONFIG_LIMIT + 1)
    if not raw or len(raw) > CONFIG_LIMIT or not raw.endswith(b"\n"):
        raise TransportError("Invalid or oversized transport configuration")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TransportError("Invalid transport configuration") from exc
    if not isinstance(value, dict):
        raise TransportError("Invalid transport configuration")
    return value


def split_origin(url: str) -> tuple[str, str, int]:
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise TransportError("Only HTTP and HTTPS servers are supported")
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise TransportError("Unsafe server URL")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise TransportError("Invalid server port") from exc
    return parsed.scheme, parsed.hostname.lower(), port


def validate_target(server: str, target: str) -> str:
    if not isinstance(target, str) or len(target) > 8192:
        raise TransportError("Invalid media URL")
    if any(ord(char) < 32 for char in target) or "\\" in target or any(char.isspace() for char in target):
        raise TransportError("Unsafe media URL")
    resolved = target if urlsplit(target).scheme else server.rstrip("/") + "/" + target.lstrip("/")
    parsed = urlsplit(resolved)
    if split_origin(resolved) != split_origin(server) or parsed.fragment:
        raise TransportError("Media URL is outside the configured server")
    server_path = urlsplit(server).path.rstrip("/")
    if server_path and parsed.path != server_path and not parsed.path.startswith(server_path + "/"):
        raise TransportError("Media URL is outside the configured server path")
    return resolved


def connection_for(url: str, timeout: float) -> tuple[http.client.HTTPConnection, str]:
    parsed = urlsplit(url)
    _, host, port = split_origin(url)
    connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    kwargs = {"host": host, "port": port, "timeout": timeout}
    if parsed.scheme == "https":
        kwargs["context"] = ssl.create_default_context()
    path = urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
    return connection_class(**kwargs), path


def open_upstream(
    server: str,
    target: str,
    token: str,
    method: str,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: float = 15,
) -> tuple[http.client.HTTPConnection, http.client.HTTPResponse, str]:
    current = validate_target(server, target)
    request_headers = {
        "Accept-Encoding": "identity",
        "Connection": "close",
    }
    if token:
        request_headers["Authorization"] = f"Bearer {token}"
    if headers:
        request_headers.update(headers)

    for redirect_count in range(MAX_REDIRECTS + 1):
        connection, path = connection_for(current, timeout)
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        if response.status not in REDIRECT_STATUSES:
            return connection, response, current
        location = response.getheader("Location")
        response.close()
        connection.close()
        if not location or redirect_count >= MAX_REDIRECTS:
            raise TransportError("Too many or invalid server redirects")
        current = validate_target(server, urljoin(current, location))
        if response.status == 303 and method != "HEAD":
            method = "GET"
            body = None
            request_headers.pop("Content-Type", None)
            request_headers.pop("Content-Length", None)

    raise TransportError("Too many server redirects")


def write_result(body: bytes, status: int) -> None:
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.write(f"\n{status}".encode())
    sys.stdout.buffer.flush()


def read_bounded(response: http.client.HTTPResponse, limit: int, deadline: float) -> bytes:
    chunks = []
    size = 0
    while True:
        remaining_time = deadline - time.monotonic()
        if remaining_time <= 0:
            raise TransportError("Server response timed out")
        if response.fp and getattr(response.fp, "raw", None):
            response.fp.raw._sock.settimeout(remaining_time)
        chunk = response.read(min(CHUNK_SIZE, limit + 1 - size))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        size += len(chunk)
        if size > limit:
            raise TransportError("Server response exceeded the SpokenShelf size limit")


def validate_content_range(value: str, content_length: str | None = None, require_total: bool = False):
    match = CONTENT_RANGE_RE.fullmatch(value)
    if not match:
        raise TransportError("Invalid upstream range response")
    start, end = int(match.group(1)), int(match.group(2))
    if end < start:
        raise TransportError("Invalid upstream range response")
    total = None if match.group(3) == "*" else int(match.group(3))
    if require_total and total is None:
        raise TransportError("Incomplete upstream range response")
    if total is not None and (total <= end or start >= total):
        raise TransportError("Invalid upstream range response")
    length = end - start + 1
    if content_length is not None and (not content_length.isdigit() or int(content_length) != length):
        raise TransportError("Mismatched upstream range length")
    return start, end, total


def request_mode() -> int:
    config = read_config()
    server = str(config.get("server", ""))
    target = str(config.get("url", ""))
    token = str(config.get("token", ""))
    method = str(config.get("method", "GET")).upper()
    max_response = int(config.get("maxResponseBytes", 8 * 1024 * 1024))
    max_request = int(config.get("maxRequestBytes", 1024 * 1024))
    timeout = float(config.get("timeout", 10))
    if method not in {"GET", "POST", "PATCH", "DELETE"}:
        raise TransportError("Unsupported request method")
    if not 0 < max_response <= 8 * 1024 * 1024 or not 0 < max_request <= 1024 * 1024:
        raise TransportError("Invalid request limits")
    if not 0 < timeout <= 30 or len(token) > 64 * 1024:
        raise TransportError("Invalid request configuration")
    raw_body = config.get("body")
    body = None if raw_body is None else str(raw_body).encode()
    if body is not None and len(body) > max_request:
        write_result(b'{"error":"Request exceeded the SpokenShelf size limit"}', 0)
        return 1
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    try:
        deadline = time.monotonic() + timeout
        connection, response, _ = open_upstream(server, target, token, method, headers, body, timeout)
        try:
            response_body = read_bounded(response, max_response, deadline)
            write_result(response_body, response.status)
            return 0
        finally:
            response.close()
            connection.close()
    except Exception:
        write_result(b'{"error":"Could not reach the Audiobookshelf server"}', 0)
        return 1


class LimitedThreadingHTTPServer(ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, config):
        self.transport_config = config
        self.connection_slots = threading.BoundedSemaphore(8)
        self.request_slots = threading.BoundedSemaphore(4)
        super().__init__(address, handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(10)
        return request, address

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "SpokenShelf"
    sys_version = ""

    def log_message(self, _format, *_args):
        return

    def send_small_error(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_HEAD(self):
        self.proxy_request("HEAD")

    def do_GET(self):
        self.proxy_request("GET")

    def proxy_request(self, method: str) -> None:
        config = self.server.transport_config
        parsed = urlsplit(self.path)
        if parsed.path != f"/{config['capability']}/media":
            self.send_small_error(404)
            return
        expected_host = f"127.0.0.1:{self.server.server_port}"
        if self.headers.get("Host") != expected_host:
            self.send_small_error(403)
            return
        values = parse_qs(parsed.query, keep_blank_values=True)
        target = values.get("url", [""])[0]
        try:
            range_header = self.headers.get("Range")
            if range_header and not RANGE_RE.fullmatch(range_header):
                raise TransportError("Invalid range")
            headers = {}
            if range_header:
                headers["Range"] = range_header
            if_range = self.headers.get("If-Range")
            if if_range and len(if_range) <= 1024 and "\r" not in if_range and "\n" not in if_range:
                headers["If-Range"] = if_range
            if not self.server.request_slots.acquire(blocking=False):
                self.send_small_error(503)
                return
            try:
                connection, response, _ = open_upstream(
                    config["server"], target, config["token"], method, headers, timeout=20
                )
                try:
                    requested_range = headers.get("Range", "")
                    content_length = response.getheader("Content-Length")
                    expected_range_length = None
                    if response.status == 206:
                        if not requested_range:
                            raise TransportError("Unsolicited upstream range response")
                        start, end, total = validate_content_range(
                            response.getheader("Content-Range", ""), content_length
                        )
                        expected_range_length = end - start + 1
                        range_value = requested_range.removeprefix("bytes=")
                        requested_start, requested_end = range_value.split("-", 1)
                        if requested_start:
                            if start != int(requested_start) or (requested_end and end > int(requested_end)):
                                raise TransportError("Mismatched upstream range response")
                        elif total is None or end != total - 1 or end - start + 1 > int(requested_end):
                            raise TransportError("Mismatched upstream suffix range")
                    if content_length and (not content_length.isdigit() or int(content_length) > MAX_MEDIA_BYTES):
                        raise TransportError("Upstream media response is too large")
                    self.send_response(response.status)
                    for name, value in response.getheaders():
                        if name.lower() in ALLOWED_RESPONSE_HEADERS and "\r" not in value and "\n" not in value:
                            self.send_header(name, value)
                    self.send_header("Connection", "close")
                    self.end_headers()
                    if method == "GET":
                        transferred = 0
                        deadline = time.monotonic() + MAX_MEDIA_SECONDS
                        while True:
                            if time.monotonic() >= deadline:
                                raise TransportError("Upstream media response timed out")
                            chunk = response.read(CHUNK_SIZE)
                            if not chunk:
                                break
                            transferred += len(chunk)
                            if transferred > MAX_MEDIA_BYTES:
                                raise TransportError("Upstream media response is too large")
                            self.wfile.write(chunk)
                        if expected_range_length is not None and transferred != expected_range_length:
                            raise TransportError("Incomplete upstream range response")
                finally:
                    response.close()
                    connection.close()
            finally:
                self.server.request_slots.release()
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception:
            try:
                self.send_small_error(502)
            except Exception:
                pass


def proxy_mode() -> int:
    config = read_config()
    server_url = str(config.get("server", ""))
    token = str(config.get("token", ""))
    split_origin(server_url)
    if not token or len(token) > 64 * 1024:
        raise TransportError("Invalid media proxy token")
    config = {"server": server_url, "token": token, "capability": secrets.token_urlsafe(32)}
    httpd = LimitedThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler, config)

    def stop_on_stdin_close():
        try:
            while sys.stdin.buffer.read(CHUNK_SIZE):
                pass
        finally:
            httpd.shutdown()

    threading.Thread(target=stop_on_stdin_close, daemon=True).start()
    print(json.dumps({"port": httpd.server_port, "capability": config["capability"]}), flush=True)
    httpd.serve_forever(poll_interval=0.25)
    httpd.server_close()
    return 0


def safe_component(value: str) -> bool:
    return value not in {"", ".", ".."} and re.fullmatch(r"[A-Za-z0-9._-]+", value) is not None


def open_directory_tree(path: Path, create: bool) -> int:
    if not path.is_absolute():
        raise TransportError("Download paths must be absolute")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open("/", flags)
    try:
        for component in path.parts[1:]:
            if create:
                try:
                    os.mkdir(component, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def book_parts(downloads_root: Path, book_root: Path) -> tuple[str, str]:
    try:
        relative = book_root.relative_to(downloads_root)
    except ValueError as exc:
        raise TransportError("Unsafe download path") from exc
    if len(relative.parts) != 2 or not all(safe_component(part) for part in relative.parts):
        raise TransportError("Unsafe download path")
    return relative.parts[0], relative.parts[1]


def open_child_directory(parent_fd: int, name: str, create: bool) -> int:
    if not safe_component(name):
        raise TransportError("Unsafe download path")
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)


def safe_regular_files(directory_fd: int) -> list[tuple[str, int]]:
    files = []
    for name in os.listdir(directory_fd):
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise TransportError("Unsafe file in download directory")
        if not (name.endswith(".audio") or name.endswith(".audio.part") or name.endswith(".part.json")):
            raise TransportError("Unexpected file in download directory")
        files.append((name, info.st_size))
    return files


def open_book_lock(scope_fd: int, book_name: str):
    lock_name = "." + book_name + ".lock"
    lock_fd = os.open(
        lock_name,
        os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=scope_fd,
    )
    lock_file = os.fdopen(lock_fd, "r+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        lock_file.close()
        raise TransportError("A download operation is already active for this book") from exc
    return lock_file


def emit_event(event: dict) -> None:
    print(json.dumps(event, separators=(",", ":")), flush=True)


def download_mode() -> int:
    config = read_config()
    server = str(config.get("server", ""))
    token = str(config.get("token", ""))
    target = str(config.get("url", ""))
    downloads_root = Path(str(config.get("downloadsRoot", "")))
    root = Path(str(config.get("bookRoot", "")))
    destination = Path(str(config.get("destination", "")))
    track_limit = int(config.get("trackLimit", 8 * 1024**3))
    book_limit = int(config.get("bookLimit", 64 * 1024**3))
    if (not downloads_root.is_absolute() or not root.is_absolute() or not destination.is_absolute()
            or not 0 < track_limit <= 8 * 1024**3 or not 0 < book_limit <= 64 * 1024**3
            or len(token) > 64 * 1024):
        raise TransportError("Invalid download configuration")
    scope_name, book_name = book_parts(downloads_root, root)
    if destination.parent != root or not re.fullmatch(r"\d+\.audio", destination.name):
        raise TransportError("Unsafe download destination")
    downloads_fd = open_directory_tree(downloads_root, create=True)
    try:
        scope_fd = open_child_directory(downloads_fd, scope_name, create=True)
        try:
            lock_file = open_book_lock(scope_fd, book_name)
            try:
                book_fd = open_child_directory(scope_fd, book_name, create=True)
                try:
                    return download_locked(server, token, target, book_fd, destination.name, track_limit, book_limit)
                finally:
                    os.close(book_fd)
            finally:
                lock_file.close()
        finally:
            os.close(scope_fd)
    finally:
        os.close(downloads_fd)


def download_locked(server, token, target, book_fd, destination, track_limit, book_limit) -> int:
    files = safe_regular_files(book_fd)
    file_sizes = dict(files)
    book_bytes = sum(size for name, size in files if not name.endswith(".json"))
    if destination in file_sizes:
        size = file_sizes[destination]
        if size > track_limit or book_bytes > book_limit:
            raise TransportError("Existing download exceeds the configured quota")
        emit_event({"event": "complete", "bytes": size})
        return 0
    part = destination + ".part"
    metadata_path = part + ".json"
    existing = file_sizes.get(part, 0)
    other_book_bytes = book_bytes - existing
    if existing > track_limit or book_bytes > book_limit:
        raise TransportError("Existing download exceeds the configured quota")
    validator = ""
    if metadata_path in file_sizes:
        try:
            metadata_fd = os.open(metadata_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=book_fd)
            with os.fdopen(metadata_fd, "r") as metadata_file:
                validator = str(json.load(metadata_file).get("validator", ""))
        except (OSError, json.JSONDecodeError, AttributeError, UnicodeDecodeError):
            validator = ""
    headers = {}
    if existing:
        headers["Range"] = f"bytes={existing}-"
        if validator:
            headers["If-Range"] = validator
    connection, response, _ = open_upstream(server, target, token, "GET", headers, timeout=30)
    try:
        if existing and response.status == 416:
            content_range = response.getheader("Content-Range", "")
            match = re.fullmatch(r"bytes \*/(\d+)", content_range)
            if match and int(match.group(1)) == existing:
                os.replace(part, destination, src_dir_fd=book_fd, dst_dir_fd=book_fd)
                try:
                    os.unlink(metadata_path, dir_fd=book_fd)
                except FileNotFoundError:
                    pass
                emit_event({"event": "complete", "bytes": existing})
                return 0
            raise TransportError("Server rejected the partial download")
        if existing and response.status == 206:
            content_range = response.getheader("Content-Range", "")
            range_start, range_end, range_total = validate_content_range(
                content_range, response.getheader("Content-Length"), require_total=True
            )
            if range_start != existing:
                raise TransportError("Server returned an invalid resume range")
        elif response.status == 200:
            existing = 0
        elif response.status == 206:
            content_range = response.getheader("Content-Range", "")
            range_start, range_end, range_total = validate_content_range(
                content_range, response.getheader("Content-Length"), require_total=True
            )
            if range_start != 0:
                raise TransportError("Server returned an unsolicited invalid range")
        else:
            raise TransportError(f"Server returned HTTP {response.status}")

        response_validator = response.getheader("ETag") or response.getheader("Last-Modified") or ""
        content_length = response.getheader("Content-Length")
        if content_length and content_length.isdigit():
            expected = existing + int(content_length)
            if expected > track_limit or other_book_bytes + expected > book_limit:
                raise TransportError("Download exceeded the configured storage quota")
        metadata_fd = os.open(
            metadata_path,
            os.O_CREAT | os.O_TRUNC | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=book_fd,
        )
        with os.fdopen(metadata_fd, "w") as metadata_file:
            json.dump({"validator": response_validator}, metadata_file)
        output_flags = os.O_CREAT | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
        output_flags |= os.O_APPEND if existing else os.O_TRUNC
        written = existing
        output_fd = os.open(part, output_flags, 0o600, dir_fd=book_fd)
        with os.fdopen(output_fd, "ab" if existing else "wb") as output:
            while True:
                chunk = response.read(CHUNK_SIZE)
                if not chunk:
                    break
                allowed = min(track_limit - written, book_limit - (other_book_bytes + written))
                if len(chunk) > allowed:
                    if allowed > 0:
                        output.write(chunk[:allowed])
                    output.flush()
                    os.fsync(output.fileno())
                    raise TransportError("Download exceeded the configured storage quota")
                output.write(chunk)
                written += len(chunk)
                emit_event({"event": "progress", "bytes": written})
            output.flush()
            os.fsync(output.fileno())
        if response.status == 206 and written != range_total:
            raise TransportError("Server returned an incomplete range")
        os.replace(part, destination, src_dir_fd=book_fd, dst_dir_fd=book_fd)
        try:
            os.unlink(metadata_path, dir_fd=book_fd)
        except FileNotFoundError:
            pass
        emit_event({"event": "complete", "bytes": written})
        return 0
    finally:
        response.close()
        connection.close()


def delete_mode() -> int:
    config = read_config()
    configured_root = Path(str(config.get("downloadsRoot", "")))
    book_root = Path(str(config.get("bookRoot", "")))
    if not configured_root.is_absolute() or not book_root.is_absolute():
        raise TransportError("Invalid deletion configuration")
    scope_name, book_name = book_parts(configured_root, book_root)
    protected = {Path(path).name for path in config.get("protectedPaths", []) if Path(path).parent == book_root}
    try:
        downloads_fd = open_directory_tree(configured_root, create=False)
    except FileNotFoundError:
        emit_event({"event": "deleted", "files": 0})
        return 0
    try:
        scope_fd = open_child_directory(downloads_fd, scope_name, create=False)
    except FileNotFoundError:
        os.close(downloads_fd)
        emit_event({"event": "deleted", "files": 0})
        return 0
    try:
        try:
            lock_file = open_book_lock(scope_fd, book_name)
            try:
                try:
                    book_fd = open_child_directory(scope_fd, book_name, create=False)
                except FileNotFoundError:
                    emit_event({"event": "deleted", "files": 0})
                    return 0
                removed = 0
                try:
                    for name, _size in safe_regular_files(book_fd):
                        if name in protected:
                            continue
                        os.unlink(name, dir_fd=book_fd)
                        removed += 1
                finally:
                    os.close(book_fd)
                try:
                    os.rmdir(book_name, dir_fd=scope_fd)
                except OSError:
                    pass
            finally:
                lock_file.close()
        finally:
            os.close(scope_fd)
    finally:
        os.close(downloads_fd)
    emit_event({"event": "deleted", "files": removed})
    return 0


def init_mode() -> int:
    config = read_config()
    state_root = Path(str(config.get("stateRoot", "")))
    state_fd = open_directory_tree(state_root, create=True)
    try:
        os.fchmod(state_fd, 0o700)
        downloads_fd = open_child_directory(state_fd, "downloads", create=True)
        os.fchmod(downloads_fd, 0o700)
        os.close(downloads_fd)
        for name in ("downloads.json", "offline-sessions.json", "server-url"):
            file_fd = os.open(
                name,
                os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=state_fd,
            )
            try:
                if not stat.S_ISREG(os.fstat(file_fd).st_mode):
                    raise TransportError("Unsafe state file")
                os.fchmod(file_fd, 0o600)
            finally:
                os.close(file_fd)
    finally:
        os.close(state_fd)
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"proxy", "request", "download", "delete", "init"}:
        return 2
    try:
        return {
            "proxy": proxy_mode,
            "request": request_mode,
            "download": download_mode,
            "delete": delete_mode,
            "init": init_mode,
        }[sys.argv[1]]()
    except Exception as exc:
        if sys.argv[1] in {"download", "delete", "init"}:
            emit_event({"event": "error", "message": str(exc)[:512]})
        elif sys.argv[1] == "request":
            write_result(b'{"error":"Transport request failed"}', 0)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
