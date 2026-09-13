[English version](./README.en.md)

# Ethereum Infra Lab

> Nodo Ethereum completo (execution + consensus) operado como infraestructura real, no como
> tutorial: Docker Compose, reverse proxy, DNS, monitoreo con Prometheus/Grafana, firewall
> y un runbook con incidentes reales encontrados y resueltos mientras se operaba.
> Corre sobre testnet Hoodi por defecto para no requerir ~2TB de disco ni días de sync.

## Por qué armé este proyecto

Vengo del lado de seguridad de smart contracts en Ethereum, y quería sumar la pata de
infraestructura: entender un protocolo no alcanza si no se sabe también operarlo —
desplegarlo, monitorearlo, asegurarlo y responder cuando algo falla en producción. Armé
este lab para practicar exactamente eso con un nodo real, corriendo en un homelab
compartido con otros servicios (no un entorno de laboratorio aislado), como preparación
para roles de infraestructura/DevOps con foco en blockchain.

## Screenshots

![Nethermind — panel general](screenshots/nethermind-overview.png)
*Nethermind Node Monitor: peers, block number, tráfico de red y versión, con data real del nodo ya sincronizado en Hoodi.*

![Nethermind — JSON-RPC](screenshots/nethermind-jsonrpc.png)
*Detalle de requests JSON-RPC (éxitos, errores, deserialization failures) — útil para detectar abuso o mala configuración de clientes.*

![Lighthouse — Network](screenshots/lighthouse-network.png)
*Lighthouse Network: peers conectados, ancho de banda libp2p, errores/warnings de dependencias (execution layer, gossipsub, discv5).*

## Aprendizajes

Operar esto en un homelab compartido, en vez de un entorno de laboratorio limpio, generó
tres incidentes reales — cada uno con su postmortem completo (diagnóstico, causa raíz,
fix) en [`RUNBOOK.md`](./RUNBOOK.md). Resumen y la lección general de cada uno:

1. **Un path de volumen mal mapeado llenó el disco.** `docker-compose.yml` montaba el
   volumen persistente de Nethermind en una ruta que la imagen no usa realmente; Docker
   creó en silencio un volumen anónimo de 67.8GB en la ubicación real, sin que nadie lo
   pidiera, y eso terminó en un crash-loop de 155 reinicios.
   **Lección**: no asumir que un path de volumen "razonable" es el correcto — verificarlo
   contra la imagen/documentación del proyecto, y monitorear el volumen que efectivamente
   crece, no el que uno cree que está usando.

2. **Subestimé el footprint de memoria de un nodo real.** Con el nodo ya sincronizado,
   `execution` + `consensus` combinados consumían ~7GB de RAM en un homelab de 13.6GB
   compartido con otros servicios, saturando el swap y rompiendo el scraping de métricas.
   **Lección**: dimensionar recursos según el consumo real de un nodo Ethereum en
   producción (no el de un tutorial en un servidor dedicado), y alertar sobre memoria
   desde el día uno, no solo sobre disco.

3. **Un dashboard comunitario de Grafana quedó desactualizado.** El dashboard de
   Nethermind más popular en Grafana.com filtraba por una etiqueta que esta versión del
   cliente ya no expone, dejando todos los paneles en "No data" sin que el datasource
   estuviera mal.
   **Lección**: verificar que las variables/queries de un dashboard importado resuelvan
   contra las métricas reales antes de darlo por bueno — "No data" no siempre significa
   que la fuente de datos está rota.

Una cuarta decisión, tomada a propósito y no por descuido: el firewall (`ufw`) quedó
**documentado pero sin activar** en el homelab real, porque ese server comparte máquina
con otros servicios (Jellyfin, TeamSpeak, Wazuh) sin reglas propias, y activarlo sin antes
relevar esos puertos los hubiera dejado inaccesibles.

## Arquitectura

```
Internet ──(Cloudflare DNS, proxy naranja)── nginx:80/443 ── grafana:3000
                                                                  │
                                                             prometheus:9090
                                                              │         │
                                                    node-exporter   ┌───┴───┐
                                                                    │       │
                                                              execution  consensus
                                                            (Nethermind) (Lighthouse)
                                                                    │       │
                                                                    └───┬───┘
                                                                  JWT compartido
                                                                (auth Engine API)
```

- **execution** (Nethermind): JSON-RPC (8545) y Engine API (8551) — **solo en la red interna de Docker**, nunca expuestos a internet (ver `nginx/nginx.conf`, motivo explicado ahí).
- **consensus** (Lighthouse): beacon node, habla con execution via Engine API autenticada por JWT.
- **prometheus + node-exporter**: métricas de los dos clientes + del host.
- **grafana**: único servicio expuesto públicamente (detrás de nginx + Cloudflare).
- **nginx**: reverse proxy y punto único de entrada.

## Por qué el RPC no se expone

Un JSON-RPC público mal configurado es el vector más común de robo de fondos y abuso de nodo
(scraping, spam de requests, exfiltración de datos privados del mempool local). Este lab
lo deja cerrado a propósito y lo documenta en `nginx/nginx.conf` y `RUNBOOK.md` (#4).

## Setup

```bash
cp .env.example .env        # editar ETH_NETWORK, password de Grafana, dominio
mkdir -p jwt
openssl rand -hex 32 > jwt/jwt.hex

docker compose up -d
docker compose logs -f execution consensus   # ver progreso de sync
```

Métricas: `docker compose ps` para confirmar que los 6 servicios están `Up`.
Grafana en `http://localhost:8090` (puerto 8090 porque 80/443 ya los usan otros
servicios del homelab) — datasource de Prometheus (`http://prometheus:9090`) y
tres dashboards ya importados:
- **Nethermind Node Monitor** — [grafana.com/grafana/dashboards/18746](https://grafana.com/grafana/dashboards/18746-nethermind/)
- **Lighthouse Summary** y **Lighthouse Network** — del repo oficial
  [sigp/lighthouse-metrics](https://github.com/sigp/lighthouse-metrics/tree/master/dashboards)

(Ojo: `grafana.com/api/dashboards/<id>` no valida que el ID sea el que uno cree —
confirmar siempre el título del dashboard antes de importarlo a ciegas.)

## DNS / Cloudflare

Paso manual, no automatizable sin tus credenciales:
1. En Cloudflare, crear un registro `A` (o `CNAME`) para `grafana.tudominio.com` apuntando
   a la IP pública del homelab, con el proxy (nube naranja) activado.
2. Puerto forwarding en el router: 80/443 públicos → IP del homelab, puerto 8090 (nginx
   corre ahí porque 80/443 ya están ocupados por otros servicios del homelab).
3. TLS: usar Cloudflare en modo "Flexible" para arrancar simple, o certbot en nginx para
   TLS end-to-end más adelante (no incluido en este lab v1).

## Firewall

`firewall/setup-ufw.sh` queda **documentado pero sin activar** a propósito: el homelab real
donde corre este proyecto comparte server con otros servicios (Jellyfin, TeamSpeak,
Portainer, Wazuh, etc.) que hoy no tienen reglas propias, y `ufw default deny incoming`
los cortaría a todos si se prende sin antes relevar esos puertos. El script sirve como
evidencia de qué reglas harían falta para este proyecto puntual — ver comentarios adentro.

## Runbook e incidentes

Ver [`RUNBOOK.md`](./RUNBOOK.md) — 8 escenarios, 3 de ellos incidentes reales con
diagnóstico completo (disco lleno, presión de memoria, dashboard con variable rota).
Simulacro de caída de servicio:

```bash
./scripts/simulate-outage.sh execution
```

## Roadmap (no implementado todavía)

- [ ] TLS end-to-end con certbot en vez de depender solo del modo Flexible de Cloudflare
- [ ] Alertmanager real (hoy las alertas solo se ven en Prometheus/Grafana, no notifican)
- [ ] Pruning / control de crecimiento de disco si se migra a mainnet

## Licencia

[MIT](./LICENSE)
