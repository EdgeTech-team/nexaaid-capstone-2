"""F-20: serve the Flutter web build locally with the headers from
web/_headers, to test the Content-Security-Policy before a Netlify deploy.

    cd mobile
    flutter build web --release
    python3 tool/serve_with_csp.py                 # enforce: problems break
    python3 tool/serve_with_csp.py --report-only   # like the first deploy

Open http://127.0.0.1:8080 and watch the DevTools console.
"""
import argparse
import functools
import http.server
import pathlib

MOBILE = pathlib.Path(__file__).resolve().parent.parent


def read_headers(enforce: bool) -> list:
    """The headers under "/*" in web/_headers, as (name, value) pairs."""
    headers = []
    for line in (MOBILE / "web" / "_headers").read_text().splitlines():
        if not line[:1].isspace() or ":" not in line:
            continue                      # comments and the "/*" line
        name, value = (part.strip() for part in line.split(":", 1))
        if enforce and name == "Content-Security-Policy-Report-Only":
            name = "Content-Security-Policy"
        headers.append((name, value))
    return headers


class Handler(http.server.SimpleHTTPRequestHandler):
    extra: list = []

    def end_headers(self):
        for name, value in self.extra:
            self.send_header(name, value)
        super().end_headers()

    def send_head(self):
        # Like web/_redirects on Netlify: unknown paths load the app.
        if not pathlib.Path(self.translate_path(self.path)).exists():
            self.path = "/index.html"
        return super().send_head()


def main():
    parser = argparse.ArgumentParser(description="Serve build/web with web/_headers.")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    Handler.extra = read_headers(enforce=not args.report_only)
    build = MOBILE / "build" / "web"
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", args.port), functools.partial(Handler, directory=str(build)))
    print(f"Serving {build} on http://127.0.0.1:{args.port} (Ctrl+C to stop)")
    server.serve_forever()


if __name__ == "__main__":
    main()


