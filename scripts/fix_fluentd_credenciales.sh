#!/bin/bash
set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " Actualizando el ConfigMap de Fluentd con credenciales"
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
      user elastic
      password Proyecto5Seguro2026!
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
      user elastic
      password Proyecto5Seguro2026!
      logstash_format true
      include_tag_key true
      tag_key log.tag
      <buffer>
        flush_interval 5s
      </buffer>
    </match>
EOF
echo "  -> ConfigMap actualizado con credenciales."

echo ""
echo "=================================================="
echo " Reiniciando Fluentd"
echo "=================================================="
kubectl rollout restart daemonset/fluentd -n "$NAMESPACE"
kubectl rollout status daemonset/fluentd -n "$NAMESPACE" --timeout=90s

echo ""
echo "=================================================="
echo " Verificando que ya no haya errores 401"
echo "=================================================="
sleep 15
kubectl logs -n "$NAMESPACE" daemonset/fluentd --tail=15

echo ""
echo "=================================================="
echo " Listo. Espera 1-2 min y en Kibana cambia el rango"
echo " de fechas a 'Last 15 minutes' o más, y refresca."
echo "=================================================="
