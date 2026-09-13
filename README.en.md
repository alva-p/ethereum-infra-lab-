[🇪🇸 Versión en español](./README.md)

# Ethereum Infra Lab

> A full Ethereum node (execution + consensus) operated as real infrastructure, not a
> tutorial: Docker Compose, reverse proxy, DNS, Prometheus/Grafana monitoring, firewall,
> and a runbook with **real incidents** found and fixed while operating it.
> Runs on the Hoodi testnet by default so it doesn't require ~2TB of disk or days of syncing.

**Three real incidents documented in [`RUNBOOK.md`](./RUNBOOK.md)**: a mismapped volume
path that filled the homelab's disk (67.8GB in an anonymous Docker volume, 155-restart
crash loop), a RAM/swap saturation that broke metrics scraping, and a community Grafana
dashboard with a broken variable that left every panel showing "No data". All three with
step-by-step diagnosis, root cause and fix — not hypothetical, they happened while running this.

## Screenshots

![Nethermind — overview](screenshots/nethermind-overview.png)
*Nethermind Node Monitor: peers, block number, network traffic and version, with real data from the already-synced Hoodi node.*

![Nethermind — JSON-RPC](screenshots/nethermind-jsonrpc.png)
*JSON-RPC request breakdown (successes, errors, deserialization failures) — useful for spotting abuse or misconfigured clients.*

![Lighthouse — Network](screenshots/lighthouse-network.png)
*Lighthouse Network: connected peers, libp2p bandwidth, dependency errors/warnings (execution layer, gossipsub, discv5).*

## How this was built

Not a copied tutorial: it got built, broken, and fixed in a real working session.
Short timeline (full detail on every incident in [`RUNBOOK.md`](./RUNBOOK.md)):

1. Initial design: Nethermind + Lighthouse in Docker Compose, a shared JWT for the Engine API, nginx exposing only Grafana (never the RPC).
2. First deploy → **incident 1**: a mismapped volume path (`/nethermind/data` instead of `/nethermind/nethermind_db`) made Docker create an anonymous volume that grew to 67.8GB in 5 hours and filled the homelab's disk → 155-restart crash loop.
3. Fix: correct the path, move the data to the HDD (`/data`, not the root SSD), add a log size limit. The node actually syncs now.
4. **Incident 2**: once synced, `execution` + `consensus` combined were using ~7GB of RAM on a 13.6GB homelab already shared with other services → swap hit 100%, Prometheus lost Lighthouse's scrape to timeouts.
5. Documented as a real resource constraint (no config shortcut fixes it) and added a `HostMemoryLow` alert to catch it earlier next time.
6. Grafana + Prometheus set up, dashboards imported from Grafana.com and Lighthouse's official repo → **incident 3**: the Nethermind dashboard (ID 18746) filtered on a label (`nethermind_group`) that doesn't exist in this client version. Diagnosed directly via PromQL, fixed without touching ~80 panels one by one.
7. Firewall (`ufw`) documented but **not enabled** on purpose: the homelab shares a server with other services (Jellyfin, TeamSpeak, Wazuh) that would've been cut off by a `deny incoming` policy without first surveying all their ports — a deliberate call, not an oversight.

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
