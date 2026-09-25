#!/bin/bash
set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " Generando certificados con un pod temporal"
echo "=================================================="
kubectl run cert-gen -n "$NAMESPACE" --rm -i --restart=Never \
  --image=docker.elastic.co/elasticsearch/elasticsearch:7.17.10 -- bash -c '
set -e
cd /tmp
/usr/share/elasticsearch/bin/elasticsearch-certutil ca --out /tmp/ca.p12 --pass "" --silent
/usr/share/elasticsearch/bin/elasticsearch-certutil cert --ca /tmp/ca.p12 --ca-pass "" \
  --out /tmp/elastic-certificates.p12 --pass "" --silent \
  --dns "elasticsearch-0.elasticsearch.kube-logging.svc.cluster.local,elasticsearch-1.elasticsearch.kube-logging.svc.cluster.local,elasticsearch-2.elasticsearch.kube-logging.svc.cluster.local,elasticsearch.kube-logging.svc.cluster.local,localhost" \
  --ip "127.0.0.1"
base64 -w0 /tmp/elastic-certificates.p12 > /tmp/cert_b64.txt
cat /tmp/cert_b64.txt
' > /tmp/cert_output.txt

echo ""
echo "=================================================="
echo " Guardando el certificado como Secret de Kubernetes"
echo "=================================================="
CERT_B64=$(tail -n 1 /tmp/cert_output.txt)
kubectl delete secret elastic-certificates -n "$NAMESPACE" --ignore-not-found=true
kubectl create secret generic elastic-certificates -n "$NAMESPACE" \
  --from-literal=elastic-certificates.p12="$(echo "$CERT_B64" | base64 -d)"

echo ""
echo "=================================================="
echo " Verificando que el Secret se creó bien"
echo "=================================================="
kubectl get secret elastic-certificates -n "$NAMESPACE"

echo ""
echo "Listo. NO avances al siguiente script todavía —"
echo "confirma conmigo que este paso salió bien primero."
