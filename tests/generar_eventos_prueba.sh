#!/bin/bash
# ============================================================
# generar_eventos_prueba.sh
#
# Qué hace: provoca cosas a propósito en el cluster (borrar un
# pod, entrar a un pod, intentos de acceso sin permiso) para que
# Fluentd las capture y aparezcan datos reales en los 5 dashboards
# de Kibana.
#
# Se puede correr varias veces — cada corrida genera más eventos
# con timestamps distintos, lo cual además ayuda al panel de
# "salud del pipeline" (que se ve más lleno con actividad repartida
# en el tiempo en vez de todo junto).
# ============================================================

set -e
NAMESPACE="kube-logging"

echo "=================================================="
echo " 1) Creando un pod de prueba (si no existe)"
echo "=================================================="
# Un pod chiquito y desechable, solo para tener algo que borrar
# y donde hacer 'exec' sin arriesgar Elasticsearch/Kibana/Fluentd.
kubectl create deployment test-app -n "$NAMESPACE" --image=nginx:alpine 2>/dev/null || echo "  (ya existe, seguimos)"
echo "  Esperando a que el pod de prueba esté listo..."
kubectl wait --for=condition=Ready pod -l app=test-app -n "$NAMESPACE" --timeout=60s || true

echo ""
echo "=================================================="
echo " 2) Panel: Eventos y fallos de pods"
echo "    -> Borramos el pod de prueba a propósito."
echo "       Kubernetes lo vuelve a crear solo (esto es normal,"
echo "       no se rompe nada), y ese 'borrado' queda como evento."
echo "=================================================="
POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app=test-app -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n "$NAMESPACE" "$POD_NAME"
echo "  Pod '$POD_NAME' borrado. Kubernetes está creando uno nuevo."

echo ""
echo "=================================================="
echo " 3) Panel: Accesos sensibles (exec / login)"
echo "    -> Esperamos a que el pod nuevo esté listo y le hacemos"
echo "       'exec' para simular que alguien entró al contenedor."
echo "=================================================="
kubectl wait --for=condition=Ready pod -l app=test-app -n "$NAMESPACE" --timeout=60s
NEW_POD=$(kubectl get pod -n "$NAMESPACE" -l app=test-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$NEW_POD" -- ls / > /dev/null
echo "  Se hizo 'exec' dentro de '$NEW_POD'."

echo ""
echo "=================================================="
echo " 4) Panel: Rechazos y errores (401/403)"
echo "    -> Le pedimos algo a la API de Kubernetes SIN credenciales."
echo "       Esto genera un 401/403 real de verdad."
echo "=================================================="
curl -sk -o /dev/null -w "  Respuesta de la API sin token: HTTP %{http_code}\n" https://localhost:6443/api/v1/namespaces || true

echo ""
echo "=================================================="
echo " 5) Panel: Rechazos y errores (extra) + accesos a Kibana"
echo "    -> Le pedimos a Kibana una página que no existe (404)"
echo "       y probamos un login con datos inventados."
echo "=================================================="
NODE_IP=$(hostname -I | awk '{print $1}')
curl -s -o /dev/null -w "  Kibana página inexistente: HTTP %{http_code}\n" "http://${NODE_IP}:32000/pagina-que-no-existe" || true
curl -s -o /dev/null -w "  Intento de login a Kibana: HTTP %{http_code}\n" \
  -X POST "http://${NODE_IP}:32000/internal/security/login" \
  -H 'Content-Type: application/json' \
  -H 'kbn-xsrf: true' \
  -d '{"providerType":"basic","providerName":"basic","currentURL":"/","params":{"username":"auditor_prueba","password":"clave_incorrecta"}}' || true

echo ""
echo "=================================================="
echo " Listo. Dale 1-2 minutos para que Fluentd mande estos"
echo " eventos a Elasticsearch, y luego revisa en Kibana > Discover."
echo " Puedes correr este script varias veces (incluso en distintos"
echo " días) para tener más datos repartidos en el tiempo."
echo "=================================================="
