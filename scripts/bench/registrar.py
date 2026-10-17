#!/usr/bin/env python3
"""Stand-in registrar for the test bench: answers REGISTER and OPTIONS with 200 OK on
127.0.0.1 (UDP), so that the bench copy of the app registers without the provider.
Calls do not go through it: the test phone (pjsua) calls the app directly."""
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5070

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", PORT))
while True:
    data, addr = sock.recvfrom(65535)
    text = data.decode("utf-8", "replace")
    if not text.strip():
        continue                      # keep-alive (CRLF)
    first, _, rest = text.partition("\r\n")
    method = first.split(" ", 1)[0]
    if method not in ("REGISTER", "OPTIONS"):
        continue
    headers = rest.split("\r\n\r\n", 1)[0].split("\r\n")
    keep = [h for h in headers if h.split(":", 1)[0].strip().lower()
            in ("via", "v", "from", "f", "call-id", "i", "cseq")]
    to = next((h for h in headers if h.split(":", 1)[0].strip().lower() in ("to", "t")), "To: <sip:bench@127.0.0.1>")
    if ";tag=" not in to:
        to += ";tag=bench"
    keep.append(to)
    if method == "REGISTER":
        contact = next((h for h in headers if h.split(":", 1)[0].strip().lower() in ("contact", "m")), None)
        expires = next((h.split(":", 1)[1].strip() for h in headers if h.lower().startswith("expires:")), "600")
        if contact:
            keep.append(contact + ("" if "expires=" in contact else f";expires={expires}"))
        keep.append(f"Expires: {expires}")
    reply = "SIP/2.0 200 OK\r\n" + "\r\n".join(keep) + "\r\nContent-Length: 0\r\n\r\n"
    sock.sendto(reply.encode(), addr)
