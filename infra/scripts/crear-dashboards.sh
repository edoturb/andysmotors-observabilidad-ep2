#!/usr/bin/env bash
#
# Crea los 2 dashboards de la EP2 directamente via la API HTTP de Grafana,
# sin depender de los menus de la UI (que cambian entre versiones).
#
# Uso:
#   GRAFANA_URL="http://<IP_PUBLICA_MONITOREO>:3000" \
#   GRAFANA_PASSWORD="Edu1234grafana" \
#   ./scripts/crear-dashboards.sh
#
# Requisitos: curl, jq.

set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:?Define GRAFANA_URL, ej: http://3.239.165.201:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:?Define GRAFANA_PASSWORD}"
AUTH="${GRAFANA_USER}:${GRAFANA_PASSWORD}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: falta 'jq'. Instalalo con: brew install jq" >&2; exit 1; }

echo "==> Buscando el datasource de Prometheus en Grafana..."
DS_UID="$(curl -sf -u "$AUTH" "$GRAFANA_URL/api/datasources" | jq -r '.[] | select(.type=="prometheus") | .uid' | head -1)"

if [[ -z "$DS_UID" || "$DS_UID" == "null" ]]; then
  echo "ERROR: no encontre un datasource de tipo Prometheus en $GRAFANA_URL." >&2
  echo "       Verifica que ya lo hayas creado en Connections > Data sources." >&2
  exit 1
fi
echo "    datasource uid: $DS_UID"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

crear_dashboard() {
  local titulo="$1" json_template="$2"
  local json_file="$TMP_DIR/dashboard.json"
  sed "s/__DS_UID__/${DS_UID}/g" "$json_template" > "$json_file"

  echo "==> Creando dashboard: $titulo"
  local respuesta
  respuesta="$(curl -sf -u "$AUTH" -X POST "$GRAFANA_URL/api/dashboards/db" \
    -H "Content-Type: application/json" \
    -d @"$json_file")"

  local url
  url="$(echo "$respuesta" | jq -r '.url // empty')"
  if [[ -z "$url" ]]; then
    echo "ERROR al crear '$titulo'. Respuesta de Grafana:" >&2
    echo "$respuesta" >&2
    exit 1
  fi
  echo "    listo: ${GRAFANA_URL}${url}"
}

# --- Dashboard 1: Infraestructura -------------------------------------------
cat > "$TMP_DIR/infraestructura.json" <<'EOF'
{
  "dashboard": {
    "id": null,
    "uid": null,
    "title": "Infraestructura AndysMotors",
    "schemaVersion": 39,
    "version": 0,
    "refresh": "30s",
    "time": { "from": "now-6h", "to": "now" },
    "panels": [
      {
        "id": 1,
        "title": "Uso de CPU (%)",
        "type": "timeseries",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
        "fieldConfig": { "defaults": { "unit": "percent" }, "overrides": [] },
        "targets": [
          {
            "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            "legendFormat": "{{instance}}",
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      },
      {
        "id": 2,
        "title": "Conexiones activas a PostgreSQL",
        "type": "stat",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 8 },
        "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
        "targets": [
          {
            "expr": "sum(pg_stat_database_numbackends)",
            "legendFormat": "Conexiones",
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      },
      {
        "id": 3,
        "title": "Estado de los backends (HAProxy)",
        "type": "table",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
        "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
        "targets": [
          {
            "expr": "haproxy_server_status",
            "format": "table",
            "instant": true,
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      }
    ]
  },
  "overwrite": true
}
EOF

# --- Dashboard 2: Negocio ----------------------------------------------------
cat > "$TMP_DIR/negocio.json" <<'EOF'
{
  "dashboard": {
    "id": null,
    "uid": null,
    "title": "Negocio AndysMotors",
    "schemaVersion": 39,
    "version": 0,
    "refresh": "30s",
    "time": { "from": "now-6h", "to": "now" },
    "panels": [
      {
        "id": 1,
        "title": "Agendamientos: Solicitados vs Confirmados",
        "type": "timeseries",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
        "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
        "targets": [
          {
            "expr": "sum(rate(agendamientos_solicitados_total[5m]))",
            "legendFormat": "Solicitados",
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          },
          {
            "expr": "sum(rate(agendamientos_confirmados_total[5m]))",
            "legendFormat": "Confirmados",
            "refId": "B",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      },
      {
        "id": 2,
        "title": "Ventas cerradas por segundo",
        "type": "timeseries",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 8 },
        "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] },
        "targets": [
          {
            "expr": "sum(rate(ventas_cerradas_total[5m]))",
            "legendFormat": "Ventas/s",
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      },
      {
        "id": 3,
        "title": "Pagos por resultado",
        "type": "timeseries",
        "datasource": { "type": "prometheus", "uid": "__DS_UID__" },
        "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
        "fieldConfig": { "defaults": { "unit": "reqps" }, "overrides": [] },
        "targets": [
          {
            "expr": "sum by (resultado) (rate(pagos_total[5m]))",
            "legendFormat": "{{resultado}}",
            "refId": "A",
            "datasource": { "type": "prometheus", "uid": "__DS_UID__" }
          }
        ]
      }
    ]
  },
  "overwrite": true
}
EOF

crear_dashboard "Infraestructura AndysMotors" "$TMP_DIR/infraestructura.json"
crear_dashboard "Negocio AndysMotors" "$TMP_DIR/negocio.json"

echo ""
echo "==> Listo. Abre en tu navegador: ${GRAFANA_URL}/dashboards"
