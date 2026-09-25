# Manual Operativo: Clúster ELK (Proyecto 5)

Este documento recopila el proceso operativo formal, flujos de datos y runbooks de respuesta ante incidentes para el Clúster ELK del Proyecto 5, alineado con los controles ISO/IEC 27001:2022 (A.5.24 y A.5.37).

---

## 1. Flujo Dinámico del Dato (Nodo ➔ Kibana)

El pipeline de ingesta captura, procesa y visualiza la actividad del clúster a través de 5 fuentes críticas. El flujo se divide en tres fases lógicas:

### A. Generación y Captura (Origen)
Logs de Auditoría de K3s: El API Server escribe directamente en `/var/log/kubernetes/audit.log` (Nivel: Metadata). Fluentd monitorea el archivo mediante colas activas bajo la etiqueta `k8s.audit`.
Eventos del Plano de Control: Eventrouter intercepta los eventos internos de Kubernetes y los redirige a la salida estándar (`stdout`). Fluentd los lee de inmediato desde el backend de contenedores.
Infraestructura y Aplicaciones: Fluentd mapea de forma nativa los directorios de los nodos (`/var/log/*`) y los contenedores del clúster (`/var/log/containers/*.log`), procesándolos con el plugin `fluent-plugin-parser-cri`.

### B. Transporte y Normalización (Procesamiento)
Fluentd (DaemonSet) unifica la estructura de los datos, añade metadatos del clúster (nodo, pod, namespace) y habilita el formato dinámico `logstash_format: true`.
El tráfico se envía cifrado mediante TLS hacia el servicio de Elasticsearch.

### C. Almacenamiento y Visualización (Destino)
Elasticsearch (StatefulSet) recibe los payloads organizándolos en índices diarios bajo el patrón `logstash-YYYY.MM.DD`. El ciclo de vida del dato es controlado por la política de retención ILM (`retencion-30-dias`), purgando la evidencia de forma automática al día 31.
Kibana (Deployment) expone los datos en el puerto NodePort 32000. Consume el Index Pattern `logstash-*` mapeando el campo `@timestamp` para renderizar los 5 dashboards analíticos de seguridad y auditoría.

---

## 2. Diagrama de Arquitectura de Datos

```text
   [ K3s Control Plane ] ➔ (Audit Log) ──┐
   [ Eventrouter Pod   ] ➔ (Stdout)     ──┼➔ [ Fluentd DaemonSet ]
   [ Aplicaciones / VM ] ➔ (/var/log)   ──┘       (CRI Parser)
                                                       │
                                             TLS (Cifrado Interno)
                                                       ▼
                                          [ Elasticsearch StatefulSet ]
                                          ├── elasticsearch-0 (Master) ➔ [PV: 5Gi]
                                          ├── elasticsearch-1 (Worker) ➔ [PV: 5Gi]
                                          └── elasticsearch-2 (Worker) ➔ [PV: 5Gi]
                                                       │
                                             Auth (elastic / auditor)
                                                       ▼
                                               [ Kibana NodePort ]
                                                (Puerto: 32000)
```

---

## 3. Procedimientos ante Eventos de Configuración (Guía de Administración)

### A. Gestión de Políticas de Retención (ILM)
Si se requiere modificar el ciclo de vida del dato (por ejemplo, extenderlo a 60 días), la política debe sobrescribirse mediante la API de Elasticsearch. No modifiques los archivos YAML de K3s.

```bash
curl -X PUT "http://localhost:9200/_ilm/policy/retencion-30-dias" \
     -u "elastic:Proyecto5Seguro2026!" \
     -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot": { "actions": {} },
      "delete": { "min_age": "30d", "actions": { "delete": {} } }
    }
  }
}'
```

### B. Re-importación de Objetos Guardados (Saved Objects)
En caso de corrupción de dashboards o pérdida del Index Pattern, restaura el estado operativo base utilizando el archivo de respaldo `export.ndjson`:

```bash
curl -X POST "http://localhost:32000/api/saved_objects/_import?createNewCopies=true" \
     -u "elastic:Proyecto5Seguro2026!" \
     -H "kbn-xsrf: true" \
     --form file=@export.ndjson
```

---

## 4. Runbook de Incidentes (Control ISO 27001 - A.5.24)

### Incidente 1: El estado del Clúster Elasticsearch cambia a "Yellow" o "Red"
Impacto: Riesgo de pérdida de logs y dashboards inaccesibles en Kibana.
Procedimiento de Mitigación:
  1. Identifica el estado de salud general ejecutando:
     ```bash
     curl -X GET "http://localhost:9200/_cluster/health?pretty" -u "elastic:Proyecto5Seguro2026!"
     ```
  2. Localiza qué pods del StatefulSet fallaron o están desincronizados:
     ```bash
     kubectl get pods -n kube-logging -l app=elasticsearch
     ```
  3. Si un nodo específico reporta fallas persistentes, forzar el reinicio ordenado del contenedor:
     ```bash
     kubectl rollout restart statefulset elasticsearch -n kube-logging
     ```

### Incidente 2: Falla de autenticación en Kibana o Alertas de Seguridad TLS
Impacto: El personal de auditoría no puede visualizar la evidencia de accesos sensibles.
Procedimiento de Mitigación:
  1. Verifica la validez y presencia del secreto que aloja los certificados de transporte de red:
     ```bash
     kubectl describe secret elastic-certificates -n kube-logging
     ```
  2. Comprueba que las credenciales declaradas en el Deployment de Kibana coincidan con el motor de base de datos interno:
     ```bash
     kubectl logs deployment/kibana -n kube-logging --tail=50
     ```

Incidente 3: Saturación de Almacenamiento Local (`local-path` al 100%)
Impacto: K3s expulsará los pods (`Evicted`) y detendrá la ingesta de las 5 fuentes.
Procedimiento de Mitigación:
  1. Ejecuta una purga forzada manual de los índices más antiguos de Logstash para liberar espacio inmediato:
     ```bash
     curl -X DELETE "http://localhost:9200/logstash-*" -u "elastic:Proyecto5Seguro2026!"
     ```
  2. Ejecuta un snapshot preventivo al repositorio local verificado para resguardar la metadata histórica antes del borrado masivo:
     ```bash
     curl -X PUT "http://localhost:9200/_snapshot/respaldo_local/snapshot_emergencia?wait_for_completion=true" -u "elastic:Proyecto5Seguro2026!"
     ```

---

## 5. Checklist Periódica de Mantenimiento (Control ISO 27001 - A.5.37)

| Frecuencia | Componente a Evaluar | Comando / Método de Verificación | Resultado Esperado |
| :--- | :--- | :--- | :--- |
| Diario | Salud del Clúster | `curl -sX GET "http://localhost:9200/_cluster/health" ...` | `status: green`, `number_of_nodes: 3` |
| Diario | Estado de los Daemons | `kubectl get daemonset fluentd -n kube-logging` | Desplegado en el 100% de los nodos aptos. |
| Semanal | Sincronización NTP | `timedatectl status` | `System clock synchronized: yes` (A.8.17). |
| Semanal | Verificación de Respaldos | `curl -X GET "http://localhost:9200/_snapshot/respaldo_local/_all" ...` | Estado del último snapshot: `"SUCCESS"`. |
| Mensual | Integridad de Roles | Intento de borrado desde Kibana con usuario `auditor`. | Retorno de error estricto `HTTP 403 Forbidden`. |
| Mensual | Cuotas de Espacio | `kubectl get pvc -n kube-logging` | Uso total asignado no superior al 80% de la capacidad física. |

---
