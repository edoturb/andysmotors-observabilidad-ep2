# AndysMotors — Observabilidad (ADY1103 · EP2)

Infraestructura como código (Terraform) y stack de observabilidad propio
(Prometheus, Grafana, Node Exporter, Postgres Exporter) para el caso
**AndysMotors**, desplegado sobre AWS Academy Learner Lab y automatizado con
un pipeline de GitHub Actions.

Basado en el caso de estudio y la infraestructura publicados en
[`asanchezo-duoc/ADY1103-Activities`](https://github.com/asanchezo-duoc/ADY1103-Activities/tree/main/Casos/AndysMotors).

## Estructura

```
.
├── infra/                        # Terraform: caso base + stack de monitoreo propio
│   ├── monitoreo_estudiante.tf   #   ← EC2 + SG para Prometheus/Grafana/exporters
│   ├── scripts/
│   │   ├── setup-monitoreo.sh    #   ← instala exporters + Prometheus + Grafana + datasource, en 1 paso
│   │   └── crear-dashboards.sh   #   ← crea ambos dashboards via la API de Grafana
│   └── ...                       #   resto del caso (compute, security, storage, etc.)
├── docs/
│   └── GUIA-DESPLIEGUE.md        # Guía paso a paso, manual y automatizada
└── .github/workflows/
    ├── terraform-ci.yml          # fmt + validate en cada push/PR
    └── terraform-deploy.yml      # plan/apply/destroy manual contra AWS Academy
```

## Qué agrega `monitoreo_estudiante.tf` sobre el caso base

El caso original solo **expone** telemetría (`/metrics` en cada plataforma,
HAProxy, logs). Este archivo crea lo que falta para observarlo:

- Una instancia EC2 adicional con Docker, donde se instalan **Prometheus** y
  **Grafana** manualmente (ver `docs/GUIA-DESPLIEGUE.md`).
- Un Security Group propio, con los puertos 3000/9090/22 abiertos solo a
  `admin_cidr`.
- Las reglas de ingreso necesarias para que esa instancia pueda scrapear las
  plataformas de negocio, HAProxy, **Node Exporter** (9100) y **Postgres
  Exporter** (9187).

## Uso rápido

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # completar con tus valores
TF_LOCAL=1 ./scripts/tf.sh init
TF_LOCAL=1 ./scripts/tf.sh plan
TF_LOCAL=1 ./scripts/tf.sh apply

# Instala exporters + Prometheus + Grafana + datasource en una sola pasada
DB_PASSWORD="..." GRAFANA_PASSWORD="..." ./scripts/setup-monitoreo.sh

# Crea ambos dashboards (Infraestructura y Negocio) via la API de Grafana
GRAFANA_URL="http://<ip-publica-monitoreo>:3000" GRAFANA_PASSWORD="..." ./scripts/crear-dashboards.sh
```

> Nota: `TF_LOCAL=1` corre Terraform instalado en tu maquina en vez del contenedor
> Docker de `tf.sh`, que por defecto no monta la carpeta `demo/` (necesaria para
> `data.archive_file.demo`). Usalo si tienes Terraform instalado localmente.

Guía completa, incluyendo exporters, PromQL, dashboards y el pipeline de
GitHub Actions: [`docs/GUIA-DESPLIEGUE.md`](./docs/GUIA-DESPLIEGUE.md).

## Pipeline

| Workflow | Disparo | Qué hace |
|---|---|---|
| `terraform-ci.yml` | Automático (push/PR) | `terraform fmt -check` + `validate` |
| `terraform-deploy.yml` | Manual | `plan` / `apply` / `destroy` contra AWS Academy |

Requiere configurar secrets de AWS y de Terraform en el repositorio — ver la
sección "Despliegue automatizado" de la guía.

## Siempre al terminar

```bash
./scripts/tf.sh destroy
```

o `Actions → Terraform Deploy (AWS Academy) → Run workflow → destroy`.
