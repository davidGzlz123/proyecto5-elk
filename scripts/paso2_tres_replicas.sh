#!/bin/bash
set -e
NAMESPACE="kube-logging"
ELASTIC_PASSWORD="Proyecto5Seguro2026!"

echo "=================================================="
echo " Actualizando el Service para incluir el puerto"
echo " de transporte (9300), necesario para que los 3"
echo " nodos se hablen entre sí"
echo "=================================================="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: $NAMESPACE
  labels:
    app: elasticsearch
spec:
  ports:
    - port: 9200
      name: rest
    - port: 9300
      name: transport
  clusterIP: None
  selector:
    app: elasticsearch
EOF

echo ""
echo "=================================================="
echo " Recreando el StatefulSet con 3 réplicas + TLS"
echo " (esto SÍ reinicia elasticsearch-0, tarda unos minutos"
echo " mientras los 3 nodos se encuentran entre sí)"
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
  replicas: 3
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
          resources:
            requests:
              memory: "800Mi"
            limits:
              memory: "1Gi"
          env:
            - name: node.name
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: discovery.seed_hosts
              value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
            - name: cluster.initial_master_nodes
              value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
            - name: ES_JAVA_OPTS
              value: "-Xms512m -Xmx512m"
            - name: xpack.security.enabled
              value: "true"
            - name: ELASTIC_PASSWORD
              value: "$ELASTIC_PASSWORD"
            - name: xpack.security.transport.ssl.enabled
              value: "true"
            - name: xpack.security.transport.ssl.verification_mode
              value: "certificate"
            - name: xpack.security.transport.ssl.keystore.path
              value: "certs/elastic-certificates.p12"
            - name: xpack.security.transport.ssl.truststore.path
              value: "certs/elastic-certificates.p12"
            - name: path.repo
              value: "/usr/share/elasticsearch/data/snapshots"
          ports:
            - containerPort: 9200
              name: rest
            - containerPort: 9300
              name: transport
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
            - name: certs
              mountPath: /usr/share/elasticsearch/config/certs
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: elastic-certificates
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
echo " Esperando a que los 3 pods estén listos (puede"
echo " tardar 2-3 minutos, ten paciencia)"
echo "=================================================="
kubectl wait --for=condition=Ready pod -l app=elasticsearch -n "$NAMESPACE" --timeout=240s || true

echo ""
echo "=================================================="
echo " Estado de los pods:"
echo "=================================================="
kubectl get pods -n "$NAMESPACE" -l app=elasticsearch

echo ""
echo "=================================================="
echo " Salud del cluster (busca 'number_of_nodes': 3)"
echo "=================================================="
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s -u "elastic:$ELASTIC_PASSWORD" \
  "http://localhost:9200/_cluster/health?pretty" || echo "  (todavía no responde, normal si acaba de arrancar - espera 1 min y vuelve a intentar el curl de arriba)"
