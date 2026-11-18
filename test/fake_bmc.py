#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
"""A stand-in MegaRAC BMC for test-launcher.sh: the web API calls the launcher
makes, over TLS with a self-signed certificate. Every request is appended to a
JSON-lines log for the test to check.

  fake_bmc.py <port file> <cert> <key> <served dir> <request log> [options]

  --no-csrf     log in without a CSRF token, as older firmware does
  --refuse      refuse every login
  --empty-jnlp  serve a launch file with no arguments
  --tls-max V   speak TLS no newer than V (1.1 for the legacy-TLS test)
"""
import argparse, http.server, json, ssl, sys, urllib.parse, warnings

USER, PASSWORD = "admin", "pa ss&=+%'*~é"
COOKIE, CSRF, TOKEN = "CookieA1b2C3d4E5f6G7h8", "CsrfZ9y8X7w6V5", "TokenQ1w2E3r4T5y6U7i8"

opt = argparse.ArgumentParser()
for a in ("portfile", "cert", "key", "served", "log"):
    opt.add_argument(a)
opt.add_argument("--no-csrf", action="store_true")
opt.add_argument("--refuse", action="store_true")
opt.add_argument("--empty-jnlp", action="store_true")
opt.add_argument("--tls-max")
o = opt.parse_args()

JNLP = """<?xml version="1.0" encoding="UTF-8"?>
<jnlp spec="1.0+" codebase="https://{ip}:443/Java">
  <information><title>JViewer</title><vendor>American Megatrends, Inc.</vendor></information>
  <security><all-permissions/></security>
  <resources><j2se version="1.5+"/><jar href="release/JViewer.jar"/></resources>
  <resources os="Windows" arch="amd64"><nativelib href="release/Win64.jar"/></resources>
  <resources os="Mac OS X" arch="x86_64"><nativelib href="release/Mac64.jar"/></resources>
  <application-desc main-class="com.ami.kvm.jviewer.JViewer">{args}
  </application-desc>
</jnlp>
"""
ARGS = ["-apptype", "JViewer", "-hostname", "{ip}", "-title", "Server &amp; Console - fake",
        "-kvmtoken", TOKEN, "-kvmport", "7578", "-webcookie", COOKIE]


class BMC(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def record(self, body=""):
        with open(o.log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "body": body,
                                "cookie": self.headers.get("Cookie"), "csrf": self.headers.get("CSRFTOKEN")}) + "\n")

    def reply(self, code, data, kind="text/html"):
        data = data.encode() if isinstance(data, str) else data
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        return self.headers.get("Cookie") == "SessionCookie=" + COOKIE and (
            o.no_csrf or self.headers.get("CSRFTOKEN") == CSRF)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        self.record(body)
        if self.path != "/rpc/WEBSES/create.asp":
            return self.reply(404, "")
        form = urllib.parse.parse_qs(body)
        ok = not o.refuse and form.get("WEBVAR_USERNAME") == [USER] and form.get("WEBVAR_PASSWORD") == [PASSWORD]
        fields = "'SESSION_COOKIE' : '%s' ,'BMC_IP_ADDR' : '127.0.0.1'" % (COOKIE if ok else "Failure_Login_IPMI_Then_LDAP")
        if ok and not o.no_csrf:
            fields += " ,'CSRFTOKEN' : '%s'" % CSRF
        self.reply(200, "//Dynamic Data Begin\n WEBVAR_JSONVAR_WEB_SESSION = \n { \n WEBVAR_STRUCTNAME_WEB_SESSION : \n"
                        " [ \n { %s },  {} ],\n HAPI_STATUS:0 }; \n//Dynamic data end\n" % fields)

    def do_GET(self):
        self.record()
        url = urllib.parse.urlparse(self.path)
        if url.path == "/rpc/WEBSES/logout.asp":
            return self.reply(200, "ok")
        if not self.authorized():
            return self.reply(401, "")
        if url.path == "/Java/jviewer.jnlp":
            ip = urllib.parse.parse_qs(url.query).get("EXTRNIP", ["?"])[0]
            args = "" if o.empty_jnlp else "".join("\n    <argument>%s</argument>" % a.format(ip=ip) for a in ARGS)
            return self.reply(200, JNLP.format(ip=ip, args=args), "application/x-java-jnlp-file")
        if url.path.startswith("/Java/release/"):
            try:
                with open("%s/%s" % (o.served, url.path[len("/Java/release/"):]), "rb") as f:
                    return self.reply(200, f.read(), "application/java-archive")
            except OSError:
                pass
        self.reply(404, "")


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(o.cert, o.key)
if o.tls_max:
    warnings.simplefilter("ignore", DeprecationWarning)
    ctx.minimum_version = ssl.TLSVersion.TLSv1
    ctx.maximum_version = {"1.0": ssl.TLSVersion.TLSv1, "1.1": ssl.TLSVersion.TLSv1_1}[o.tls_max]
    ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), BMC)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.handle_error = lambda request, address: None  # a refused handshake is part of the test
with open(o.portfile, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
