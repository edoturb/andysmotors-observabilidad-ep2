#!/usr/bin/env bash
#
# Automatiza lo que hasta ahora haciamos a mano por SSH cada vez que el Lab
# de AWS Academy se reinicia y las instancias quedan con IPs nuevas:
#
#   - Node Exporter en "app" y "borde"
#   - Postgres Exporter en "app"
#   - Prometheus (con el prometheus.yml ya apuntando a las IPs privadas
#     correctas, que no cambian)
#   - Grafana
#
# Es idempotente: si un contenedor ya existe, lo recrea limpio en vez de
# fallar. Se puede correr las veces que haga falta.
#
# Uso (desde la carpeta infra/, DESPUES de un terraform apply exitoso):
#
#   TF_LOCAL=1 ./scripts/tf.sh apply
#   DB_PASSWORD="Edu1234urbina" GRAFANA_PASSWORD="Edu1234grafana" ./scripts/setup-monitoreo.sh
#
# Requisitos: terraform, jq, ssh, el archivo labsuser.pem en esta carpeta.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INFRA_DIR"

DB_PASSWORD="${DB_PASSWORD:?Define DB_PASSWORD, ej: DB_PASSWORD=Edu1234urbina ./scripts/setup-monitoreo.sh}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:?Define GRAFANA_PASSWORD, ej: GRAFANA_PASSWORD=Edu1234grafana ./scripts/setup-monitoreo.sh}"
DB_USER="${DB_USER:-andysadmin}"
DB_NAME="${DB_NAME:-andysmotors}"
PEM="${PEM:-labsuser.pem}"
SSH_OPTS=(-i "$PEM" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

command -v jq >/dev/null 2>&1 || { echo "ERROR: falta 'jq'. Instálalo con: brew install jq" >&2; exit 1; }
[[ -f "$PEM" ]] || { echo "ERROR: no encuentro $PEM en $INFRA_DIR" >&2; exit 1; }

echo "==> Leyendo outputs de Terraform..."
OUT="$(terraform output -json)"

ip_pub_app="$(echo "$OUT" | jq -r '.ips_publicas.value.app')"
ip_pub_borde="$(echo "$OUT" | jq -r '.ips_publicas.value.borde')"
ip_priv_app="$(echo "$OUT" | jq -r '.ips_privadas.value.app')"
ip_priv_borde="$(echo "$OUT" | jq -r '.ips_privadas.value.borde')"
ip_pub_mon="$(echo "$OUT" | jq -r '.monitoreo_estudiante_ip_publica.value')"

for v in ip_pub_app ip_pub_borde ip_priv_app ip_priv_borde ip_pub_mon; do
  val="${!v}"
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "ERROR: no pude leer '$v' de 'terraform output -json'. Revisa los nombres de output con: terraform output" >&2
    exit 1
  fi
done

echo "    app:       pub=$ip_pub_app   priv=$ip_priv_app"
echo "    borde:     pub=$ip_pub_borde priv=$ip_priv_borde"
echo "    monitoreo: pub=$ip_pub_mon"

ssh_run() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "ec2-user@${host}" "$@"
}

wait_for_ssh() {
  local host="$1" intentos=0
  echo "==> Esperando SSH en $host..."
  until ssh_run "$host" "true" 2>/dev/null; do
    intentos=$((intentos + 1))
    if (( intentos > 30 )); then
      echo "ERROR: $host no respondio SSH tras 5 minutos. Revisa admin_cidr/tu IP actual." >&2
      exit 1
    fi
    sleep 10
  done
}

echo ""
echo "==> [app] Node Exporter + Postgres Exporter"
wait_for_ssh "$ip_pub_app"
ssh_run "$ip_pub_app" bash -s <<EOF
  set -e
  docker rm -f node-exporter postgres-exporter >/dev/null 2>&1 || true

  docker run -d --name node-exporter --restart unless-stopped \
    --net="host" --pid="host" -v "/:/host:ro" \
    prom/node-exporter:latest --path.rootfs=/host

  docker run -d --name postgres-exporter --restart unless-stopped \
    --net="host" \
    -e DATA_SOURCE_NAME="postgresql://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}?sslmode=disable" \
    quay.io/prometheuscommunity/postgres-exporter:latest

  sleep 2
  curl -sf localhost:9100/metrics >/dev/null && echo "    node-exporter OK"
  curl -sf localhost:9187/metrics >/dev/null && echo "    postgres-exporter OK"
EOF

echo ""
echo "==> [borde] Node Exporter"
wait_for_ssh "$ip_pub_borde"
ssh_run "$ip_pub_borde" bash -s <<'EOF'
  set -e
  docker rm -f node-exporter >/dev/null 2>&1 || true

  docker run -d --name node-exporter --restart unless-stopped \
    --net="host" --pid="host" -v "/:/host:ro" \
    prom/node-exporter:latest --path.rootfs=/host

  sleep 2
  curl -sf localhost:9100/metrics >/dev/null && echo "    node-exporter OK"
EOF

echo ""
echo "==> [monitoreo] Prometheus + Grafana"
wait_for_ssh "$ip_pub_mon"
ssh_run "$ip_pub_mon" bash -s <<EOF
  set -e
  docker rm -f prometheus grafana >/dev/null 2>&1 || true

  mkdir -p ~/monitoring/prometheus
  cat > ~/monitoring/prometheus/prometheus.yml <<YAML
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "andys-plataformas"
    static_configs:
      - targets:
          - "${ip_priv_app}:8081"
          - "${ip_priv_app}:8082"
          - "${ip_priv_app}:8083"
          - "${ip_priv_app}:8084"
          - "${ip_priv_app}:8085"
        labels:
          servicio: "andys-motors"

  - job_name: "haproxy"
    static_configs:
      - targets: ["${ip_priv_borde}:8404"]
        labels:
          rol: "borde"

  - job_name: "node-exporter"
    static_configs:
      - targets: ["${ip_priv_app}:9100", "${ip_priv_borde}:9100"]

  - job_name: "postgres-exporter"
    static_configs:
      - targets: ["${ip_priv_app}:9187"]
YAML

  docker run -d --name prometheus --restart unless-stopped \
    -v ~/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
    -v prometheus_data:/prometheus \
    -p 9090:9090 \
    prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus

  docker run -d --name grafana --restart unless-stopped \
    --net="host" \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_PASSWORD}" \
    -v grafana_data:/var/lib/grafana \
    grafana/grafana:latest

  sleep 3
  curl -sf localhost:9090/-/healthy >/dev/null && echo "    prometheus OK"
  curl -sf localhost:3000/api/health >/dev/null && echo "    grafana OK"

  # Datasource de Prometheus en Grafana, via API (evita el paso manual en la UI).
  sleep 5
  curl -s -u admin:${GRAFANA_PASSWORD} -X POST http://localhost:3000/api/datasources \
    -H "Content-Type: application/json" \
    -d '{"name":"Prometheus","type":"prometheus","url":"http://localhost:9090","access":"proxy","isDefault":true}' \
    | grep -q '"datasource"' && echo "    datasource Prometheus OK" || echo "    datasource Prometheus: ya existia o fallo (revisar)"
EOF

echo ""
echo "==> Listo. Abre en tu navegador:"
echo "    Prometheus: http://${ip_pub_mon}:9090/targets"
echo "    Grafana:    http://${ip_pub_mon}:3000  (admin / \$GRAFANA_PASSWORD)"
echo ""
echo "NOTA: Grafana guarda sus dashboards en el volumen 'grafana_data' de la"
echo "instancia de monitoreo. Como esa instancia NO se destruyo (solo app/"
echo "borde quedaron con el stack de negocio), tus dashboards guardados"
echo "deberian seguir ahi. El datasource de Prometheus tambien se mantiene"
echo "(apunta a http://localhost:9090, que no cambia)."
