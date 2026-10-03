# ---------------------------------------------------------------------------
# Stack de monitoreo propio (EP2 - ADY1103)
#
# El caso base (archivos restantes de esta carpeta) solo EXPONE telemetria.
# Este archivo crea la pieza que falta: una instancia EC2 donde el estudiante
# instala Prometheus, Grafana y los exporters (Node Exporter, Postgres
# Exporter) por su cuenta, via SSH. Terraform solo entrega Docker listo.
#
# Se mantiene separado del resto de la infraestructura del caso para que sea
# facil de identificar que fue agregado para la evaluacion, y para poder
# borrarlo sin tocar el entorno de Andys Motors si se quiere repetir el
# ejercicio desde cero.
# ---------------------------------------------------------------------------

resource "aws_security_group" "monitoreo_estudiante" {
  name        = "${var.project_name}-monitoreo-estudiante-sg"
  description = "Stack de monitoreo propio: Prometheus, Grafana y exporters"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-monitoreo-estudiante-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "mon_est_grafana" {
  security_group_id = aws_security_group.monitoreo_estudiante.id
  description        = "UI de Grafana"
  cidr_ipv4          = var.admin_cidr
  from_port          = 3000
  to_port            = 3000
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "mon_est_prometheus" {
  security_group_id = aws_security_group.monitoreo_estudiante.id
  description        = "UI y API de Prometheus"
  cidr_ipv4          = var.admin_cidr
  from_port          = 9090
  to_port            = 9090
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "mon_est_ssh" {
  security_group_id = aws_security_group.monitoreo_estudiante.id
  description        = "SSH de administracion"
  cidr_ipv4          = var.admin_cidr
  from_port          = 22
  to_port            = 22
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "mon_est_salida" {
  security_group_id = aws_security_group.monitoreo_estudiante.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1"
}

# --- Permisos de scraping hacia el caso base --------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_desde_monitoreo_estudiante" {
  for_each = local.puertos

  security_group_id            = aws_security_group.app.id
  description                  = "Scraping de ${each.key} desde el monitoreo del estudiante"
  referenced_security_group_id = aws_security_group.monitoreo_estudiante.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_node_exporter" {
  security_group_id            = aws_security_group.app.id
  description                  = "Node Exporter"
  referenced_security_group_id = aws_security_group.monitoreo_estudiante.id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_postgres_exporter" {
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres Exporter"
  referenced_security_group_id = aws_security_group.monitoreo_estudiante.id
  from_port                    = 9187
  to_port                      = 9187
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "borde_metricas_estudiante" {
  security_group_id            = aws_security_group.borde.id
  description                  = "Scraping de HAProxy desde el monitoreo del estudiante"
  referenced_security_group_id = aws_security_group.monitoreo_estudiante.id
  from_port                    = 8404
  to_port                      = 8404
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "borde_node_exporter" {
  security_group_id            = aws_security_group.borde.id
  description                  = "Node Exporter en ServerBorde"
  referenced_security_group_id = aws_security_group.monitoreo_estudiante.id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
}

# --- Instancia ---------------------------------------------------------------

resource "aws_instance" "monitoreo_estudiante" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  # IP fija con cidrhost(), en .220: fuera del rango .200+len(servidores) que
  # ya usan los servidores del caso, para no colisionar con ellos.
  private_ip                  = cidrhost(data.aws_subnet.elegida.cidr_block, 220)
  vpc_security_group_ids      = [aws_security_group.monitoreo_estudiante.id]
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  # Deliberadamente minimo: solo deja Docker listo. Prometheus, Grafana y los
  # exporters los instala el estudiante por SSH (ver docs/GUIA-DESPLIEGUE.md),
  # porque instalarlos es justamente lo que se evalua.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  EOT

  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted              = true
    delete_on_termination  = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.project_name}-monitoreo-estudiante"
    Rol  = "monitoreo-estudiante"
  }
}

output "monitoreo_estudiante_ip_publica" {
  description = "IP publica del servidor donde se instala Prometheus y Grafana."
  value       = aws_instance.monitoreo_estudiante.public_ip
}

output "monitoreo_estudiante_ip_privada" {
  description = "IP privada del servidor de monitoreo (fija, no cambia al reiniciar)."
  value       = aws_instance.monitoreo_estudiante.private_ip
}
