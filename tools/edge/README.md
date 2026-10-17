# HTTPS on the server's own IP address (no tunnel, no VPN, no domain)

A manual recipe, run on one host; the installer does not automate it. Part of [Hermes Mobile Surfaces](../../README.md).

If the phone should reach Hermes from any network without a PC, a VPN app or a domain name, put nginx in front of the two
loopback services and give it a certificate for the server's **public IP address**. Let's Encrypt issues these since
January 2026: valid about six days, renewed automatically, validated over HTTP-01 on port 80
([announcement](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)). Android trusts it like any other
certificate, so the app needs no special trust setting.

1. Take any ACME client with RFC 8738 and certificate-profile support. The reference deployment used
   [lego](https://github.com/go-acme/lego) v5.5.2 (verify the archive against the published checksums file). Issue:

   ```sh
   lego run --path /opt/hermes-edge/lego --accept-tos --domains <public IPv4> --http --http.address :80 \
            --profile shortlived --key-type ec256
   ```

   Port 80 must be free and reachable only for the few seconds of a validation. Try `--server
   https://acme-staging-v02.api.letsencrypt.org/directory` first: staging has separate rate limits and the flow is
   identical. No e-mail address is required.
2. Install the template [`nginx-hermes-edge.conf.tmpl`](nginx-hermes-edge.conf.tmpl): it exposes **only** the Gateway API
   and the Surfaces phone API (never the author MCP), behind a random secret path segment, with rate limiting, and closes
   every other request without an answer. Run `nginx -t` before reloading.
3. Renew with a systemd timer that runs the same `lego run ...` command (add `--deploy-hook` to copy the certificate and
   reload nginx). A run before the renewal window prints "Skip renewal" and issues nothing, so twice a day is safe.
4. In the app, add the chat connection with `https://<ip>` as host, the port, your API key and the path prefix
   `/<secret>/gw`. For the Surfaces connection line, put `https://<ip>:<port>/<secret>/ms` into
   `/etc/hermes-surfaces/public-url` and ask for a code (see the main README, "Pair the phone").

What this changes about the risk: the Hermes API server can run a terminal. It is now reachable from the internet, guarded
by TLS, an unguessable path, rate limiting and a 256-bit API key. Keep the key out of chats, repositories and backups,
rotate it if a phone is lost (`API_SERVER_KEY` in Hermes' `.env`, then restart the gateway), and watch
`/var/log/nginx/hermes-edge.access.log`. If that exposure is not acceptable, use a VPN instead.
