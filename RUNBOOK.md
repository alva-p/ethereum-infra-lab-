# Runbook de incidentes

## 1. Alerta `TargetDown` (execution o consensus caído)

**Detección**: Grafana/Prometheus dispara `TargetDown` (ver `monitoring/alerts.yml`).

**Diagnóstico**:
```
docker compose ps
docker compose logs --tail=200 execution   # o consensus
```

**Causas comunes**: OOM del container, crash por JWT mismatch, disco lleno.

**Remediación**:
```
docker compose restart execution
```
Si vuelve a caer en <5 min, revisar `docker stats` (memoria) y `df -h` (disco) antes de reintentar.

## 2. Consensus no sincroniza / execution y consensus no se hablan

**Síntoma**: `consensus` loguea `Execution engine call failed` o similar.

**Causa típica**: el `jwt/jwt.hex` no es idéntico en ambos containers, o `execution` no levantó el puerto 8551.

**Chequeo**:
```
docker compose exec execution cat /jwt/jwt.hex
docker compose exec consensus cat /jwt/jwt.hex
```
Deben ser el mismo archivo (montado desde `./jwt`, no se regenera solo).

## 3. Disco lleno (`HostDiskSpaceLow`)

El chain data de `execution`/`consensus` crece indefinidamente. En una testnet (hoodi) es manejable; en mainnet hay que planificar pruning.

**Remediación de emergencia**: liberar espacio de logs de Docker (`docker system df`, `docker system prune` con cuidado de no tocar volúmenes de datos).

## 4. RPC/Engine expuesto sin querer

**Estado real (2026-09-12)**: `ufw` está inactivo en este homelab (`firewall/setup-ufw.sh`
queda documentado pero sin aplicar, ver ese archivo para el por qué). Hoy la única
protección real de 8545/8551 es que `docker-compose.yml` **no** les publica un
`ports:` hacia el host — solo son alcanzables dentro de la red interna de Docker.

Si en algún momento se agrega un `ports:` para 8545/8551 en el compose (por ejemplo
para debuggear), es un incidente de seguridad, no un detalle menor. Revertirlo
inmediatamente (sacar esa línea del compose y `docker compose up -d`), y si además
ufw ya estuviera activo para entonces:
```
sudo ufw deny 8545
sudo ufw deny 8551
```

## 5. Incidente real: ruta de datos mal mapeada llena el disco

**Qué pasó** (2026-09-12): el `docker-compose.yml` montaba el volumen persistente de
Nethermind en `/nethermind/data`, pero el path real que usa la imagen es
`/nethermind/nethermind_db`. Docker creó un volumen anónimo en esa ruta real que
creció a **67.8GB** en ~5 horas (cada crash-loop reintentaba sync sin limpiar el
intento anterior), llenó la SSD raíz del homelab (99% de uso) y tumbó a `execution`
en un loop de reinicios (`exit code 104`, 155 reinicios). Sin execution disponible,
`consensus` quedaba con `el_offline: true` y el `sync_distance` solo crecía.

**Cómo se detectó**: el signo fue `sync_distance` subiendo en vez de bajar en un
chequeo manual — la alerta `HostDiskSpaceLow` de Prometheus también lo hubiera
agarrado, pero no había nadie mirando Grafana en ese momento (lección: una alerta
que nadie ve no sirve, hace falta Alertmanager + notificación real, ver Roadmap).

**Diagnóstico que lo encontró**:
```
docker inspect execution --format '{{.State.ExitCode}} {{.RestartCount}}'
docker inspect execution --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'
docker system df -v   # mostró el volumen anónimo de 67.8GB
```

**Fix**: corregir el path del volumen (`/nethermind/nethermind_db`) y mover los
datos del nodo de la SSD raíz (compartida con otros servicios del homelab) al
HDD `/data` (778GB libres), con bind mounts explícitos en vez de volúmenes nombrados
para poder inspeccionar el tamaño real en cualquier momento con `du`.

## 6. Presión de memoria: execution + consensus pesan más que el resto del homelab junto

**Qué se encontró** (2026-09-12): con el nodo recién sincronizado, `docker stats` mostró
`execution` en 3.37GB de RAM (102% CPU) y `consensus` en 3.79GB — **~7.1GB combinados**
en un homelab de 13.6GB total que ya corre Wazuh, Netdata, Portainer y varias apps más.
El swap terminó al 100% de uso, y eso causaba timeouts intermitentes de Prometheus
scrapeando las métricas de Lighthouse (el propio proceso, saturado, tardaba más de
10s en responder su endpoint `/metrics`) — se veía como dashboards en Grafana con
"No data" para Lighthouse, sin que el nodo estuviera realmente caído.

**No es un bug de este proyecto**: correr un nodo Ethereum completo (incluso en testnet)
es genuinamente pesado en RAM. Es una limitación real de recursos de este homelab
compartido, no algo que se arregle con código.

**Mitigación aplicada**: `scrape_timeout: 12s` en el job de `lighthouse` (por debajo del
`scrape_interval` de 15s) para tolerar latencia bajo presión sin marcar el target como
caído de forma innecesaria, más una alerta `HostMemoryLow` (`monitoring/alerts.yml`)
para detectar esto antes la próxima vez.

**Si vuelve a pasar y hace falta liberar RAM de verdad**: parar servicios no esenciales
del homelab temporalmente, o correr este lab en una ventana horaria en la que no compita
con otras cargas — no hay atajo de configuración que reduzca el uso real de un nodo
Ethereum sincronizando.

## 7. Dashboard de Nethermind sin data (variable `$group` inexistente)

**Qué pasó** (2026-09-12): el dashboard comunitario de Grafana.com (ID 18746) usa dos
variables — `$group` y `$enode` — para poder graficar múltiples nodos Nethermind a la vez.
`$group` se define como `label_values(nethermind_group)`, pero esta versión de Nethermind
(1.39.3) **no expone ninguna métrica con la etiqueta `nethermind_group`**. La variable
quedaba vacía, `$enode` (que depende de `$group`) también, y los ~80 paneles que filtran
por `{instance="$enode", nethermind_group="$group"}` no matcheaban nada → "No data" en
todo el dashboard aunque Prometheus sí tenía la data.

**Por qué el fix funciona (dos partes)**: en PromQL, un label ausente en una serie se
trata como igual a cadena vacía (`""`) para efectos de matching. Cambiando la variable
`$group` de tipo `query` a tipo `custom` con un único valor fijo `""`, el filtro
`nethermind_group=""` matchea correctamente todas las series (donde el label no existe),
sin tocar los ~80 paneles uno por uno. Pero la query que resuelve `$enode` —
`label_values({nethermind_group="$group"}, instance)` — quedaba con un **único matcher
vacío** (`nethermind_group=""`), y Prometheus rechaza selectores donde *todos* los
matchers son vacíos (`match[] must contain at least one non-empty matcher`, error real
que tiró Grafana). Fix: agregar `job="nethermind"` como matcher no-vacío en esa query
puntual → `label_values({nethermind_group="$group", job="nethermind"}, instance)`.

**Lección**: dashboards comunitarios de Grafana.com pueden quedar desactualizados
respecto a cambios en el esquema de métricas del proyecto que documentan — siempre
verificar que las variables de un dashboard importado resuelvan a algo antes de asumir
que "No data" significa que el datasource está mal.

## 8. Simulacro de caída de servicio

`./scripts/simulate-outage.sh execution` (o `consensus`) tira el servicio a propósito. Objetivo: medir tiempo entre la caída real y que la alerta aparezca en Grafana, y practicar los pasos de arriba sin presión real.
