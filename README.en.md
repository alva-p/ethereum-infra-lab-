[Versión en español](./README.md)

# Ethereum Infra Lab

> A full Ethereum node (execution + consensus) operated as real infrastructure, not a
> tutorial: Docker Compose, reverse proxy, DNS, Prometheus/Grafana monitoring, firewall,
> and a runbook with real incidents found and fixed while operating it.
> Runs on the Hoodi testnet by default so it doesn't require ~2TB of disk or days of syncing.

## Why I built this

I come from the smart contract security side of Ethereum, and wanted to add the
infrastructure piece: understanding a protocol isn't enough if you can't also operate it —
deploy it, monitor it, secure it, and respond when something breaks in production. I built
this lab to practice exactly that with a real node, running on a homelab shared with other
services (not an isolated lab environment), as preparation for infrastructure/DevOps roles
with a blockchain focus.

## Screenshots

![Nethermind — overview](screenshots/nethermind-overview.png)
*Nethermind Node Monitor: peers, block number, network traffic and version, with real data from the already-synced Hoodi node.*

![Nethermind — JSON-RPC](screenshots/nethermind-jsonrpc.png)
*JSON-RPC request breakdown (successes, errors, deserialization failures) — useful for spotting abuse or misconfigured clients.*

![Lighthouse — Network](screenshots/lighthouse-network.png)
*Lighthouse Network: connected peers, libp2p bandwidth, dependency errors/warnings (execution layer, gossipsub, discv5).*

## Lessons learned

Operating this on a shared homelab, instead of a clean lab environment, produced three
real incidents — each with a full postmortem (diagnosis, root cause, fix) in
[`RUNBOOK.md`](./RUNBOOK.md). Summary and the general takeaway from each:

1. **A mismapped volume path filled the disk.** `docker-compose.yml` mounted
   Nethermind's persistent volume at a path the image doesn't actually use; Docker
   silently created an anonymous 67.8GB volume at the real path, unrequested, which
   eventually caused a 155-restart crash loop.
   **Takeaway**: never assume a "reasonable-looking" volume path is the correct one —
   verify it against the image/project docs, and monitor the volume that's actually
   growing, not the one you think you're using.

2. **I underestimated a real node's memory footprint.** Once synced, `execution` +
   `consensus` combined were using ~7GB of RAM on a 13.6GB homelab shared with other
   services, saturating swap and breaking metrics scraping.
   **Takeaway**: size resources for a real Ethereum node's actual footprint (not a
   tutorial's, on a dedicated box), and alert on memory from day one, not just disk.

3. **A community Grafana dashboard had gone stale.** The most popular Nethermind
   dashboard on Grafana.com filtered on a label this client version no longer exposes,
   leaving every panel showing "No data" even though the datasource itself was fine.
   **Takeaway**: verify that an imported dashboard's variables/queries actually resolve
   against real metrics before trusting it — "No data" doesn't always mean the data
   source is broken.

A fourth decision was deliberate, not an oversight: the firewall (`ufw`) is
**documented but not enabled** on the real homelab, because that server shares a
machine with other services (Jellyfin, TeamSpeak, Wazuh) that don't have their own
rules yet, and enabling it without first surveying those ports would have cut them off.

## Architecture

```
Internet ──(Cloudflare DNS, orange-cloud proxy)── nginx:80/443 ── grafana:3000
                                                                       │
                                                                  prometheus:9090
                                                                   │         │
                                                         node-exporter   ┌───┴───┐
                                                                         │       │
                                                                   execution  consensus
                                                                 (Nethermind) (Lighthouse)
                                                                         │       │
                                                                         └───┬───┘
                                                                       shared JWT
                                                                    (Engine API auth)
```

- **execution** (Nethermind): JSON-RPC (8545) and Engine API (8551) — **only on Docker's internal network**, never exposed to the internet (see `nginx/nginx.conf` for why).
- **consensus** (Lighthouse): beacon node, talks to execution via the JWT-authenticated Engine API.
- **prometheus + node-exporter**: metrics for both clients plus the host.
- **grafana**: the only publicly exposed service (behind nginx + Cloudflare).
- **nginx**: reverse proxy and single entry point.

## Why the RPC isn't exposed

A misconfigured public JSON-RPC is the most common vector for fund theft and node abuse
(scraping, request spam, leaking private local-mempool data). This lab keeps it closed on
purpose and documents it in `nginx/nginx.conf` and `RUNBOOK.md` (#4).

## Setup

```bash
cp .env.example .env        # edit ETH_NETWORK, Grafana password, domain
mkdir -p jwt
openssl rand -hex 32 > jwt/jwt.hex

docker compose up -d
docker compose logs -f execution consensus   # watch sync progress
```

Health check: `docker compose ps` to confirm all 6 services are `Up`.
Grafana at `http://localhost:8090` (port 8090 because 80/443 are already taken by other
services on the homelab) — a Prometheus datasource (`http://prometheus:9090`) and three
dashboards already imported:
- **Nethermind Node Monitor** — [grafana.com/grafana/dashboards/18746](https://grafana.com/grafana/dashboards/18746-nethermind/)
- **Lighthouse Summary** and **Lighthouse Network** — from the official
  [sigp/lighthouse-metrics](https://github.com/sigp/lighthouse-metrics/tree/master/dashboards) repo

(Heads up: `grafana.com/api/dashboards/<id>` doesn't validate that the ID is the one you
think it is — always confirm a dashboard's title before importing it blindly.)

## DNS / Cloudflare

Manual step, can't be automated without your credentials:
1. In Cloudflare, create an `A` (or `CNAME`) record for `grafana.yourdomain.com` pointing
   to the homelab's public IP, with the proxy (orange cloud) on.
2. Port forwarding on the router: public 80/443 → homelab IP, port 8090 (nginx runs there
   because 80/443 are already taken by other services on the homelab).
3. TLS: use Cloudflare's "Flexible" mode to keep it simple, or certbot on nginx for
   end-to-end TLS later (not included in this lab v1).

## Firewall

`firewall/setup-ufw.sh` is **documented but deliberately not enabled**: the real homelab
running this project shares a server with other services (Jellyfin, TeamSpeak, Portainer,
Wazuh, etc.) that don't have their own rules yet, and `ufw default deny incoming` would
cut off all of them if enabled without first surveying those ports. The script stands as
evidence of what rules this specific project would need — see the comments inside.

## Runbook and incidents

See [`RUNBOOK.md`](./RUNBOOK.md) — 8 scenarios, 3 of them real incidents with full
diagnosis (disk full, memory pressure, broken dashboard variable). Simulate a service outage:

```bash
./scripts/simulate-outage.sh execution
```

## Roadmap (not implemented yet)

- [ ] End-to-end TLS with certbot instead of relying only on Cloudflare's Flexible mode
- [ ] Real Alertmanager (today alerts are only visible in Prometheus/Grafana, no notifications)
- [ ] Pruning / disk growth control if migrating to mainnet

## License

[MIT](./LICENSE)
