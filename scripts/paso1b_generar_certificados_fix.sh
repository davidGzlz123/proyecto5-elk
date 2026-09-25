#!/bin/bash
set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " Limpiando intento anterior"
echo "=================================================="
kubectl delete secret elastic-certificates -n "$NAMESPACE" --ignore-not-found=true
kubectl delete pod cert-gen -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0 2>/dev/null || true

echo ""
echo "=================================================="
echo " Creando pod temporal (se queda dormido, no se auto-borra)"
echo "=================================================="
kubectl run cert-gen -n "$NAMESPACE" --restart=Never \
  --image=docker.elastic.co/elasticsearch/elasticsearch:7.17.10 \
  --command -- sleep 3600

kubectl wait --for=condition=Ready pod/cert-gen -n "$NAMESPACE" --timeout=60s

echo ""
echo "=================================================="
echo " Generando el certificado DENTRO del pod"
echo "=================================================="
kubectl exec -n "$NAMESPACE" cert-gen -- bash -c '
set -e
cd /tmp
/usr/share/elasticsearch/bin/elasticsearch-certutil ca --out /tmp/ca.p12 --pass "" --silent
/usr/share/elasticsearch/bin/elasticsearch-certutil cert --ca /tmp/ca.p12 --ca-pass "" \
  --out /tmp/elastic-certificates.p12 --pass "" --silent \
  --dns "elasticsearch-0.elasticsearch.kube-logging.svc.cluster.local,elasticsearch-1.elasticsearch.kube-logging.svc.cluster.local,elasticsearch-2.elasticsearch.kube-logging.svc.cluster.local,elasticsearch.kube-logging.svc.cluster.local,localhost" \
  --ip "127.0.0.1"
ls -la /tmp/elastic-certificates.p12
'

echo ""
echo "=================================================="
echo " Copiando el archivo del pod a tu VM (binario, sin pasar"
echo " por texto de terminal esta vez)"
echo "=================================================="
kubectl cp "$NAMESPACE/cert-gen:/tmp/elastic-certificates.p12" ./elastic-certificates.p12
ls -la ./elastic-certificates.p12

echo ""
echo "=================================================="
echo " Creando el Secret desde el archivo ya en tu VM"
echo "=================================================="
kubectl create secret generic elastic-certificates -n "$NAMESPACE" \
  --from-file=elastic-certificates.p12=./elastic-certificates.p12

echo ""
echo "=================================================="
echo " Limpiando el pod temporal"
echo "=================================================="
kubectl delete pod cert-gen -n "$NAMESPACE"

echo ""
echo "=================================================="
echo " Verificación final"
echo "=================================================="
kubectl get secret elastic-certificates -n "$NAMESPACE"
echo ""
echo "Tamaño del archivo local (debe ser varios KB, NO 0 bytes):"
ls -la ./elastic-certificates.p12

echo ""
echo "Listo. Pégame el tamaño del archivo que salió arriba antes"
echo "de seguir al siguiente paso."
