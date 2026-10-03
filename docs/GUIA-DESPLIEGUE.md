# Guía de despliegue — ADY1103 EP2 (AndysMotors)

Despliegue manual (Terminal) y automatizado (GitHub Actions) de la infraestructura
y el stack de observabilidad propio (Prometheus, Grafana, Node Exporter, Postgres
Exporter) sobre AWS Academy Learner Lab.

## 0. Parámetros a definir

| Parámetro | Cómo obtenerlo |
|---|---|
| `admin_cidr` | `curl -s ifconfig.me` → `<tu-ip>/32` |
| `db_password` | Definir (12-41 caracteres, sin `/ " @` ni espacios) |
| `grafana_admin_password` | Definir (mín. 12 caracteres) |
| `admin_token` | Definir, o usar `andys-lab` |
| `project_name` | ej. `andys-tu-apellido` |
| Credenciales AWS Academy | Learner Lab → **AWS Details → AWS CLI** |
| `labsuser.pem` | Learner Lab → **AWS Details → Download PEM** |

## 1. Despliegue manual (Terminal)

```bash
# [Terminal local]
cd infra
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars con los valores de la tabla anterior

cat > .aws-credentials <<'EOF'
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
EOF
chmod 600 .aws-credentials

./scripts/tf.sh init
./scripts/tf.sh plan
./scripts/tf.sh apply
./scripts/tf.sh output
```

Verificación:

```bash
curl -s http://<IP_BORDE>/
curl -s http://<IP_BORDE>:8404/stats     # todas las plataformas en UP
```

## 2. Instalar los exporters (Node Exporter, Postgres Exporter)

```bash
# [EC2 app/data - SSH]
ssh -i labsuser.pem ec2-user@<IP_PUBLICA_APP>

docker run -d --name node-exporter --restart unless-stopped \
  --net="host" --pid="host" -v "/:/host:ro,rslave" \
  prom/node-exporter:latest --path.rootfs=/host

docker run -d --name postgres-exporter --restart unless-stopped \
  --net="host" \
  -e DATA_SOURCE_NAME="postgresql://andysadmin:<DB_PASSWORD>@localhost:5432/andysmotors?sslmode=disable" \
  quay.io/prometheuscommunity/postgres-exporter:latest
```

```bash
# [EC2 borde - SSH] (opcional, cobertura del balanceador)
ssh -i labsuser.pem ec2-user@<IP_PUBLICA_BORDE>
docker run -d --name node-exporter --restart unless-stopped \
  --net="host" --pid="host" -v "/:/host:ro,rslave" \
  prom/node-exporter:latest --path.rootfs=/host
```

## 3. Instalar Prometheus

```bash
# [EC2 monitoreo-estudiante - SSH]
ssh -i labsuser.pem ec2-user@<MONITOREO_IP_PUBLICA>

mkdir -p ~/monitoring/prometheus
cat > ~/monitoring/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "andys-plataformas"
    static_configs:
      - targets: ["<IP_PRIVADA_APP>:8081","<IP_PRIVADA_APP>:8082","<IP_PRIVADA_APP>:8083","<IP_PRIVADA_APP>:8084","<IP_PRIVADA_APP>:8085"]
        labels: { servicio: "andys-motors" }

  - job_name: "haproxy"
    static_configs:
      - targets: ["<IP_PRIVADA_BORDE>:8404"]
        labels: { rol: "borde" }

  - job_name: "node-exporter"
    static_configs:
      - targets: ["<IP_PRIVADA_APP>:9100","<IP_PRIVADA_BORDE>:9100"]

  - job_name: "postgres-exporter"
    static_configs:
      - targets: ["<IP_PRIVADA_APP>:9187"]
EOF

docker run -d --name prometheus --restart unless-stopped \
  -v ~/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  -v prometheus_data:/prometheus -p 9090:9090 \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus
```

Verificar en `http://<MONITOREO_IP_PUBLICA>:9090/targets`: todos los jobs en **UP**.

## 4. Instalar Grafana y conectar el Datasource

```bash
# [EC2 monitoreo-estudiante - SSH]
docker run -d --name grafana --restart unless-stopped \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD="<GRAFANA_PASSWORD>" \
  -v grafana_data:/var/lib/grafana -p 3000:3000 \
  grafana/grafana:latest
```

En `http://<MONITOREO_IP_PUBLICA>:3000`: Connections → Data sources → Prometheus
→ URL `http://localhost:9090` → Save & test.

## 5. Generar tráfico de negocio

```bash
cd demo
./scripts/generar_trafico.py --url http://<IP_PUBLICA_BORDE> --hora-inicio 10 --factor 1 --duracion 1800
```

## 6. Consultas PromQL de referencia

```promql
sum(rate(http_requests_total[5m])) by (servicio)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, servicio))
sum(rate(agendamientos_solicitados_total[5m])) - sum(rate(agendamientos_confirmados_total[5m]))
```

## 7. Dashboards

- **Infraestructura**: CPU/memoria (`node_exporter`), conexiones (`pg_stat_database`), estado de backends (`haproxy_server_status`).
- **Negocio AndysMotors**: `agendamientos_solicitados_total` vs `agendamientos_confirmados_total`, `ventas_cerradas_total`, `pagos_total{resultado}`.

## 8. Evidencia de continuidad operativa

```bash
# [EC2 app - SSH]
export ANDYS_ADMIN_TOKEN=<ADMIN_TOKEN>
cd /opt/andys && ./demo/scripts/escenario.sh activar agenda_silenciosa
```

```bash
# [Terminal local]
for i in $(seq 1 15); do
  curl -s -o /dev/null -X POST http://<IP_PUBLICA_BORDE>/api/agendar \
    -H 'Content-Type: application/json' \
    -d "{\"nombre\":\"Cliente $i\",\"sucursal\":\"Providencia\",\"fecha_visita\":\"2026-10-15\"}"
done
```

Capturar en Grafana cómo crece la brecha, luego desactivar el escenario:

```bash
./demo/scripts/escenario.sh desactivar agenda_silenciosa
```

## 9. Apagar todo

```bash
cd infra
./scripts/tf.sh destroy
```

---

## Despliegue automatizado (GitHub Actions)

Este repositorio incluye dos workflows en `.github/workflows/`:

| Workflow | Disparo | Qué hace |
|---|---|---|
| `terraform-ci.yml` | Automático en cada push/PR a `infra/**` | `terraform fmt -check` + `terraform validate`. No necesita credenciales de AWS. |
| `terraform-deploy.yml` | Manual (`workflow_dispatch`) | `plan`, `apply` o `destroy` contra AWS Academy, según la acción elegida. |

### Configurar los secrets del repositorio

`Settings → Secrets and variables → Actions → New repository secret`:

| Secret | Valor |
|---|---|
| `AWS_ACCESS_KEY_ID` | Del panel AWS Details → AWS CLI |
| `AWS_SECRET_ACCESS_KEY` | Ídem |
| `AWS_SESSION_TOKEN` | Ídem |
| `TF_VAR_ADMIN_CIDR` | `<tu-ip>/32` |
| `TF_VAR_DB_PASSWORD` | Password de la base de datos |
| `TF_VAR_GRAFANA_ADMIN_PASSWORD` | Password de Grafana |
| `TF_VAR_ADMIN_TOKEN` | Token del panel de fallas |
| `TF_VAR_PROJECT_NAME` | Prefijo de los recursos |

> **Las credenciales de AWS Academy expiran al cerrar la sesión del lab.**
> Antes de cada `apply`/`destroy` desde Actions hay que volver a copiar
> `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` con
> valores frescos del panel. Por eso `terraform-deploy.yml` es manual y no se
> dispara solo en cada push.

### Ejecutar el pipeline

`Actions → Terraform Deploy (AWS Academy) → Run workflow → elegir "plan", "apply" o "destroy"`.

Se recomienda crear un *environment* llamado `aws-academy` en
`Settings → Environments` y exigir aprobación manual antes de `apply`/`destroy`,
para evitar ejecuciones accidentales.
