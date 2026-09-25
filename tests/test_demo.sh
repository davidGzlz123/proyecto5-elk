#!/bin/bash
# ============================================================
# escenario_demo_vivo.sh (o test_general.sh)
#
# Pensado para correr EN VIVO durante la presentación, no antes.
# Genera un "incidente" real paso a paso, con pausas, para que
# lo vayas narrando y luego lo reconstruyas desde los logs en
# Kibana frente al profesor.
#
# Uso: ./escenario_demo_vivo.sh
# Entre cada paso te pide [Enter] para continuar — así controlas
# el ritmo tú, no el script.
# ============================================================

NAMESPACE="kube-logging"

pausa() {
  echo ""
  read -p ">>> Presiona [Enter] para el siguiente paso... "
  echo ""
}

echo "=================================================="
echo " ESCENARIO: 'Un atacante entra, explora y borra algo'"
echo " (todo esto queda registrado en tiempo real)"
echo "=================================================="
pausa

echo "PASO 0 — Preparando el entorno (Pod y Secret de prueba)"
echo "--------------------------------------------------"
kubectl run test-app --image=nginx:alpine -n "$NAMESPACE" --labels="app=test-app"
kubectl create secret generic test-secret --from-literal=password=12345 -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo "Esperando a que el pod inicie correctamente..."
kubectl wait --for=condition=Ready pod/test-app -n "$NAMESPACE" --timeout=60s
pausa

echo "PASO 1 — Alguien intenta ver los pods sin permiso"
echo "--------------------------------------------------"
curl -sk -o /dev/null -w "Respuesta: HTTP %{http_code} (esperado: 401)\n" \
  https://localhost:6443/api/v1/pods
echo "-> Esto debería aparecer en el panel 'Rechazos y errores'."
pausa

echo "PASO 2 — El 'atacante' logra acceso y explora un pod (exec)"
echo "--------------------------------------------------"
POD=$(kubectl get pod -n "$NAMESPACE" -l app=test-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$POD" -- whoami
echo "-> Esto queda en 'Accesos sensibles' (objectRef.subresource: exec)."
pausa

echo "PASO 3 — Revisa (lee) un secret del namespace"
echo "--------------------------------------------------"
kubectl get secrets -n "$NAMESPACE" -o name | head -1 | xargs -I{} kubectl get {} -n "$NAMESPACE" -o yaml > /dev/null
echo "-> Esto también cae en 'Accesos sensibles' (objectRef.resource: secrets)."
pausa

echo "PASO 4 — Borra el pod (el 'incidente')"
echo "--------------------------------------------------"
kubectl delete pod -n "$NAMESPACE" "$POD"
echo "-> Esto es lo que vas a 'investigar' en Kibana: quién borró"
echo "   este pod y cuándo."
pausa

echo "=================================================="
echo " Listo. Espera 1-2 minutos y ve a Kibana."
echo ""
echo " Guion sugerido para reconstruir el incidente en vivo:"
echo "  1. Ve al dashboard, panel 'Eventos de pods' -> muestra"
echo "     el pico nuevo de 'delete'"
echo "  2. Ve a Discover, filtra: log.tag: k8s.audit AND verb: delete"
echo "     AND objectRef.resource: pods"
echo "  3. Expande el resultado más reciente -> muestra el campo"
echo "     user.username (quién lo hizo) y @timestamp (cuándo)"
echo "  4. Repite el filtro con objectRef.subresource: exec para"
echo "     mostrar que antes de borrar, hubo un acceso al pod"
echo "  5. Cierra mostrando que el usuario 'auditor' (solo lectura)"
echo "     no puede alterar esta evidencia -- demuéstralo copiando esto:"
echo ""
echo "     kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u auditor:Auditor2026Solo! -X DELETE \"http://localhost:9200/logstash-*\""
echo ""
echo "     (debe fallar con el error de security_exception y status 403)"
echo "=================================================="
