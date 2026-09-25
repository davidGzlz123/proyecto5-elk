#!/bin/bash
set -e
NAMESPACE="kube-logging"

kubectl delete statefulset elasticsearch -n "$NAMESPACE" --ignore-not-found=true

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
kubectl exec -n "$NAMESPACE" elasticsearch-0 -- curl -s localhost:9200/_cluster/health?pretty
