#!/bin/bash
# ============================================================
# agregar_audit_log_a_fluentd.sh
#
# Actualiza la configuración de Fluentd para que, además de los
# logs de contenedores (lo que ya tenía), también lea el nuevo
# audit log del API Server (/var/log/kubernetes/audit.log) y lo
# mande a Elasticsearch, al mismo índice logstash-* de siempre.
#
# No hace falta crear un Index Pattern nuevo en Kibana: las
# entradas de audit log van a aparecer en logstash-* junto con
# el resto, pero se distinguen fácil porque tienen campos como
# "verb", "user" y "requestURI" que los logs normales no tienen.
# ============================================================

set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " Actualizando el ConfigMap de Fluentd"
echo "=================================================="
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: kube-logging
data:
  fluent.conf: |
    <source>
      @type tail
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type cri
      </parse>
    </source>

    <source>
      @type tail
      path /var/log/kubernetes/audit.log
      pos_file /var/log/fluentd-audit.log.pos
      tag k8s.audit
      read_from_head true
      <parse>
        @type json
      </parse>
    </source>

    <match kubernetes.**>
      @type elasticsearch
      host elasticsearch.kube-logging.svc.cluster.local
      port 9200
      logstash_format true
      include_tag_key true
      tag_key log.tag
      <buffer>
        flush_interval 5s
      </buffer>
    </match>

    <match k8s.audit>
      @type elasticsearch
      host elasticsearch.kube-logging.svc.cluster.local
      port 9200
      logstash_format true
      include_tag_key true
      tag_key log.tag
      <buffer>
        flush_interval 5s
      </buffer>
    </match>
EOF
echo "  -> ConfigMap actualizado."

echo ""
echo "=================================================="
echo " Reiniciando los pods de Fluentd para que tomen"
echo " la nueva configuración"
echo "=================================================="
kubectl rollout restart daemonset/fluentd -n "$NAMESPACE"
kubectl rollout status daemonset/fluentd -n "$NAMESPACE" --timeout=90s

echo ""
echo "=================================================="
echo " Listo. Espera 1-2 minutos y luego en Kibana > Discover"
echo " busca: log.tag: k8s.audit"
echo " Si te salen resultados, la fuente #5 ya está integrada."
echo "=================================================="
