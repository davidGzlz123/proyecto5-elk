#!/bin/bash
# ============================================================
# habilitar_audit_log.sh
#
# Habilita el audit log del API Server en k3s (fuente de log
# #5 que faltaba: quién hizo qué, a qué recurso, y cuándo).
#
# Seguro de correr más de una vez (idempotente) — si ya existe
# la configuración, no la duplica.
#
# Requiere sudo. Al final reinicia k3s, así que espera unos
# 20-30 segundos y luego confirma con 'kubectl get nodes'.
# ============================================================

set -e

echo "=================================================="
echo " Paso 1: Carpeta de logs + política de auditoría"
echo "=================================================="
sudo mkdir -p /var/log/kubernetes

sudo tee /etc/rancher/k3s/audit-policy.yaml > /dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
EOF
echo "  -> /etc/rancher/k3s/audit-policy.yaml creado."

echo ""
echo "=================================================="
echo " Paso 2: Configurar k3s para usar la política"
echo "=================================================="
CONFIG_FILE="/etc/rancher/k3s/config.yaml"
sudo mkdir -p /etc/rancher/k3s

if [ -f "$CONFIG_FILE" ] && sudo grep -q "audit-log-path" "$CONFIG_FILE" 2>/dev/null; then
  echo "  -> Ya estaba configurado el audit log en $CONFIG_FILE, no se duplica."
else
  sudo tee -a "$CONFIG_FILE" > /dev/null <<'EOF'
kube-apiserver-arg:
  - "audit-log-path=/var/log/kubernetes/audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=30"
EOF
  echo "  -> Agregado a $CONFIG_FILE."
fi

echo ""
echo "=================================================="
echo " Paso 3: Reiniciar k3s"
echo "=================================================="
sudo systemctl restart k3s
echo "  -> k3s reiniciando, esperando 25 segundos..."
sleep 25

echo ""
echo "=================================================="
echo " Verificación"
echo "=================================================="
echo "  Estado del nodo:"
kubectl get nodes

echo ""
echo "  Buscando el archivo de audit log (puede tardar unos"
echo "  segundos más en aparecer si el nodo acaba de reiniciar):"
if sudo test -f /var/log/kubernetes/audit.log; then
  echo "  -> ¡Existe! Últimas líneas:"
  sudo tail -n 5 /var/log/kubernetes/audit.log
else
  echo "  -> Todavía no aparece. Espera 1 minuto más y corre:"
  echo "     sudo tail -n 5 /var/log/kubernetes/audit.log"
fi

echo ""
echo "=================================================="
echo " Listo. NO toques Fluentd todavía — confirma primero"
echo " que el audit.log sí se está llenando de líneas nuevas"
echo " (por ejemplo, corre 'kubectl get pods' un par de veces"
echo " y checa si el archivo crece)."
echo "=================================================="
