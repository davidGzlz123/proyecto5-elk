#!/bin/bash
# ============================================================
# cubrir_gaps_restantes.sh
#
# Cubre 3 de los 4 pendientes técnicos:
#  - A.8.17: verificación de sincronización de reloj (NTP)
#  - A.8.13: repositorio de snapshots + snapshot de respaldo
#  - A.8.15 reforzado: usuario de solo lectura (no puede borrar/alterar)
#
# NO toca lo de 3 nodos (eso va aparte, es más riesgoso).
#
# Esto SÍ requiere activar seguridad en Elasticsearch, así que
# Elasticsearch y Kibana se van a reiniciar (tarda 1-2 min).
# Después de esto, tanto Elasticsearch como Kibana van a pedir
# usuario y contraseña.
# ============================================================

set -e
NAMESPACE="kube-logging"
ELASTIC_PASSWORD="Proyecto5Seguro2026!"
READONLY_PASSWORD="Auditor2026Solo!"

echo "=================================================="
echo " A.8.17 - Verificando sincronización de reloj (NTP)"
echo "=================================================="
timedatectl status || true
echo ""
echo "  ^ Guarda esta salida para tu docs/iso27001.md."
echo "  Busca la línea 'System clock synchronized: yes'."

echo ""
echo "=================================================="
echo " Habilitando seguridad + path.repo en Elasticsearch"
echo " (esto reinicia el pod, tarda un momento)"
echo "=================================================="
kubectl delete statefulset elasticsearch -n "$NAMESPACE" --ignore-not-found=true

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: $NAMESPACE
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
      initContainers:
        - name: fix-permissions
          image: busybox
          command: ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:7.17.10
          env:
            - name: discovery.type
              value: single-node
            - name: xpack.security.enabled
              value: "true"
            - name: ELASTIC_PASSWORD
              value: "$ELASTIC_PASSWORD"
            - name: path.repo
              value: "/usr/share/elasticsearch/data/snapshots"
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

kubectl wait --for=condition=Ready pod/elasticsearch-0 -n "$NAMESPACE" --timeout=120s
echo "  -> Elasticsearch arriba con seguridad activada."

echo ""
echo "=================================================="
echo " Actualizando Kibana para que use las credenciales"
echo "=================================================="
kubectl set env deployment/kibana -n "$NAMESPACE" \
  ELASTICSEARCH_USERNAME=elastic \
  ELASTICSEARCH_PASSWORD="$ELASTIC_PASSWORD"
kubectl rollout status deployment/kibana -n "$NAMESPACE" --timeout=90s

echo ""
echo "=================================================="
echo " A.8.15 reforzado - Creando usuario de solo lectura"
echo "=================================================="
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/_security/role/solo_lectura" \
  -H 'Content-Type: application/json' -d'
{
  "indices": [
    { "names": ["logstash-*"], "privileges": ["read", "view_index_metadata"] }
  ]
}'

echo ""
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/_security/user/auditor" \
  -H 'Content-Type: application/json' -d"
{
  \"password\": \"$READONLY_PASSWORD\",
  \"roles\": [\"solo_lectura\"],
  \"full_name\": \"Usuario auditor de solo lectura\"
}"

echo ""
echo ""
echo "=================================================="
echo " A.8.13 - Repositorio de snapshots + snapshot de respaldo"
echo "=================================================="
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "http://localhost:9200/_snapshot/respaldo_local" \
  -H 'Content-Type: application/json' -d'
{
  "type": "fs",
  "settings": { "location": "/usr/share/elasticsearch/data/snapshots" }
}'

echo ""
FECHA=$(date +%Y%m%d_%H%M%S)
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "http://localhost:9200/_snapshot/respaldo_local/snapshot_$FECHA?wait_for_completion=true"

echo ""
echo ""
echo "=================================================="
echo " LISTO. Guarda estas credenciales:"
echo ""
echo "   Usuario admin (elastic):  $ELASTIC_PASSWORD"
echo "   Usuario solo lectura (auditor): $READONLY_PASSWORD"
echo ""
echo " Kibana ahora pide login: usuario 'elastic', esa contraseña."
echo " Para demostrar en la presentación que el usuario 'auditor'"
echo " NO puede borrar, intenta esto (debe fallar con 403):"
echo ""
echo "   curl -u auditor:$READONLY_PASSWORD -X DELETE http://localhost:9200/logstash-*"
echo "=================================================="
