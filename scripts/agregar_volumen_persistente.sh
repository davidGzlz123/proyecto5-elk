#!/bin/bash
# ============================================================
# agregar_volumen_persistente.sh
#
# Borra el Elasticsearch actual (que no tenía volumen persistente)
# y lo vuelve a crear con un PersistentVolumeClaim de 5Gi, usando
# el StorageClass "local-path" que k3s trae instalado por default.
#
# IMPORTANTE: esto borra los datos actuales de Elasticsearch
# (índices, dashboards, index patterns). Asegúrate de haber
# exportado tus Saved Objects (dashboards) desde Kibana ANTES
# de correr este script.
# ============================================================

set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " Borrando el StatefulSet actual de Elasticsearch"
echo " (el Service se deja igual, no se toca)"
echo "=================================================="
kubectl delete statefulset elasticsearch -n "$NAMESPACE" --ignore-not-found=true

echo ""
echo "=================================================="
echo " Creando el nuevo Elasticsearch, ahora con volumen"
echo " persistente (5Gi, storageClass local-path)"
echo "=================================================="
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: kube-logging
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:7.17.10
          env:
            - name: discovery.type
              value: single-node
          ports:
            - containerPort: 9200
              name: rest
              protocol: TCP
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 5Gi
EOF

echo ""
echo "=================================================="
echo " Esperando a que el nuevo pod esté listo..."
echo "=================================================="
kubectl wait --for=condition=Ready pod/elasticsearch-0 -n "$NAMESPACE" --timeout=120s

echo ""
echo "=================================================="
echo " Verificación"
echo "=================================================="
echo "  PVC creado:"
kubectl get pvc -n "$NAMESPACE"
echo ""
echo "  Estado de Elasticsearch:"
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s localhost:9200/_cluster/health?pretty

echo ""
echo "=================================================="
echo " Listo. Ahora, DESDE ANTES de apagar el VM:"
echo " 1. Vuelve a correr el script de retención (config_retencion.sh)"
echo "    para recrear la política de 30 días (se borró junto con"
echo "    el Elasticsearch anterior)."
echo " 2. En Kibana, importa el .ndjson que exportaste (Stack"
echo "    Management > Saved Objects > Import) para recuperar"
echo "    tus 5 dashboards y el index pattern."
echo " 3. Corre otra vez generar_eventos_prueba.sh para tener"
echo "    datos frescos que mostrar en los dashboards."
echo " Después de eso, ya SÍ puedes apagar el VM sin perder nada."
echo "=================================================="
