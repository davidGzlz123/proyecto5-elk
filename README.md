# Guía de Instalación y Despliegue — ELK Stack (Proyecto 5)

Esta guía describe la arquitectura, requisitos e instalación de un entorno ELK Stack de recolección de eventos y logs de un clúster Kubernetes basado en k3s, con los requisitos del proyecto para la centralización de evidencia. Elasticsearch se despliega como un clúster de 3 nodos con TLS entre ellos, seguridad activada, respaldo por snapshot y un usuario de solo lectura para consulta de evidencia.

## Índice

1. [Arquitectura](#1-arquitectura)
2. [Requisitos](#2-requisitos)
3. [Fuentes de log](#3-fuentes-de-log)
4. [Instalación](#4-instalación)
5. [Validación](#5-validación)
6. [Acceso a Kibana](#6-acceso-a-kibana)
7. [Credenciales](#7-credenciales)
8. [Respaldo y retención](#8-respaldo-y-retención)
9. [Dashboards de Kibana](#9-dashboards-de-kibana)

---

## 1. Arquitectura

El sistema está compuesto por cuatro componentes principales, con Elasticsearch desplegado como un clúster de **3 nodos** con TLS entre ellos:

```text
                         ┌──────────────────────┐
                         │    Kubernetes/k3s    │
                         │                      │
                         │  Nodos / Aplicaciones│
                         └──────────┬───────────┘
                                    │
        ┌───────────────┬──────────┼──────────┬───────────────┐
        │               │          │          │               │
        ▼               ▼          ▼          ▼               ▼
  ┌──────────┐   ┌───────────┐ ┌───────────┐  │        ┌──────────────┐
  │ Auditoría│   │  Eventos  │ │Logs de    │  │        │ Logs de      │
  │ API Server│   │    K8s    │ │ nodo/host │  │        │ aplicaciones │
  └────┬─────┘   └─────┬─────┘ └─────┬─────┘  │        └──────┬───────┘
       │               │             │        │               │
       │               ▼             │        │               │
       │         ┌────────────┐      │        │               │
       │         │Eventrouter │      │        │               │
       │         └──────┬─────┘      │        │               │
       │                │            │        │               │
       └────────────────┴─────┬──────┴────────┴───────────────┘
                               ▼
                      ┌────────────────┐
                      │    Fluentd     │
                      │  (DaemonSet,   │
                      │  parser CRI)   │
                      └───────┬────────┘
                               │ TLS
                               ▼
        ┌───────────────────────────────────────────┐
        │        Elasticsearch (3 nodos)             │
        │  elasticsearch-0 / -1 / -2 · TLS entre      │
        │  nodos · xpack.security · vol. 5Gi c/u      │
        └──────────────────────┬──────────────────────┘
                                │ login (elastic / auditor)
                                ▼
                      ┌─────────────────┐
                      │     Kibana      │
                      │ Dashboards /    │
                      │   Evidencias    │
                      └─────────────────┘
```

- **Elasticsearch:** almacena la evidencia y los logs. Se despliega como un `StatefulSet` de **3 réplicas** (`elasticsearch-0`, `elasticsearch-1`, `elasticsearch-2`) con la imagen `docker.elastic.co/elasticsearch/elasticsearch:7.17.10`. Cada nodo tiene un **volumen persistente de 5Gi** (`storageClassName: local-path`). Tiene **seguridad activada** (`xpack.security.enabled: true`, usuario administrador `elastic`) y **TLS entre nodos** (`xpack.security.transport.ssl`), con un certificado compartido guardado como `Secret` de Kubernetes (`elastic-certificates`). El descubrimiento entre nodos usa `discovery.seed_hosts` apuntando a los 3 pods por DNS interno. Estado de salud confirmado: `"status": "green"`, `"number_of_nodes": 3`, `"active_shards_percent_as_number": 100.0`.
- **Kibana:** permite visualizar y buscar los eventos almacenados en Elasticsearch. Usa la versión `7.17.10`, se expone por `NodePort` en el puerto `32000` y está configurado con `ELASTICSEARCH_USERNAME`/`ELASTICSEARCH_PASSWORD` para autenticarse contra Elasticsearch. **Ahora pide login al entrar.**
- **Eventrouter:** captura los eventos del plano de control de Kubernetes con un RBAC de **solo lectura** sobre `events`, y los envía a `stdout` para que Fluentd los recolecte.
- **Fluentd:** recolecta los logs, corre como `DaemonSet` en cada nodo, se ejecuta como `root`, usa `fluent-plugin-parser-cri` y envía todo a Elasticsearch con `logstash_format: true`.

**Índices:** patrón `logstash-YYYY.MM.DD`. Index Pattern en Kibana: `logstash-*`, campo de tiempo `@timestamp`.

## 2. Requisitos

| Requisito | Mínimo recomendado | Usado en este proyecto |
|---|---|---|
| Sistema operativo | Ubuntu Server 20.04 LTS o superior | Ubuntu Server |
| CPU | 2 vCPUs | — |
| RAM | 7.3 GB (necesarios para correr 3 réplicas de Elasticsearch con TLS y seguridad en la misma VM) |
| Almacenamiento | 20 GB libres | 20 GB + 5Gi por nodo de Elasticsearch (3 × 5Gi) |
| Kubernetes | k3s instalado y funcionando | k3s, namespace `kube-logging` |
| CLI | `kubectl` configurado | — |


## 3. Fuentes de log

El proyecto centraliza 5 fuentes de evidencia:

| # | Fuente | Cómo se captura |
|---|---|---|
| 1 | Auditoría del API Server | Audit log de Kubernetes (nivel Metadata), `/var/log/kubernetes/audit.log`, leído por Fluentd con el tag `k8s.audit` |
| 2 | Eventos de Kubernetes | Eventrouter → `stdout` → Fluentd |
| 3 | Logs de nodo | Fluentd lee `/var/log` del host |
| 4 | Logs de aplicaciones | Fluentd lee `/var/log/containers/*.log` |
| 5 | Logs de acceso a Kibana | El pod de Kibana se recolecta como cualquier otro contenedor |

## 4. Instalación

Esta sección resume los archivos base del despliegue. 

### 4.1 Crear el namespace

Crear `00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-logging
```

Aplicar:

```bash
kubectl apply -f 00-namespace.yaml
```

### 4.2 Elasticsearch (3 nodos, con TLS y seguridad)

`01-elasticsearch.yaml` despliega el `StatefulSet` de 3 réplicas, con el volumen persistente de 5Gi por nodo, `xpack.security.enabled: true` y TLS entre nodos usando el `Secret` `elastic-certificates`. El servicio interno usa el puerto `9200`.

```bash
kubectl apply -f 01-elasticsearch.yaml
kubectl get pods -n kube-logging -w
```

Verifica que los 3 pods (`elasticsearch-0`, `elasticsearch-1`, `elasticsearch-2`) queden en `Running` antes de continuar.

### 4.3 Kibana

`02-kibana.yaml` despliega Kibana, configurado con `ELASTICSEARCH_USERNAME`/`ELASTICSEARCH_PASSWORD` para autenticarse contra el clúster. Kibana escucha internamente en `5601` y se publica mediante `NodePort` en `32000`.

```bash
kubectl apply -f 02-kibana.yaml
```

### 4.4 Eventrouter

`03-eventrouter.yaml` incluye el `ServiceAccount`, `ClusterRole` (solo lectura sobre `events`), `ClusterRoleBinding`, `Deployment` y `ConfigMap`:

```bash
kubectl apply -f 03-eventrouter.yaml
```

### 4.5 Fluentd

`04-fluentd.yaml` despliega el `DaemonSet` que lee las 5 fuentes de log (sección 3) y las envía a Elasticsearch:

```bash
kubectl apply -f 04-fluentd.yaml
```

## 5. Validación

Comprobar que los pods estén funcionando (deben aparecer 3 pods de Elasticsearch, más Kibana, Eventrouter y Fluentd):

```bash
kubectl get pods -n kube-logging
```

Consultar la salud del clúster (debe mostrar `"status": "green"` y `"number_of_nodes": 3`):

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:<CONTRASEÑA> \
  "http://localhost:9200/_cluster/health?pretty"
```

Consultar los índices de Elasticsearch:

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:<CONTRASEÑA> \
  "http://localhost:9200/_cat/indices?v"
```

Debe aparecer un índice con el patrón:

```text
logstash-YYYY.MM.DD
```

Esto indica que los registros están llegando a Elasticsearch.


## 6. Acceso a Kibana

Abrir en el navegador:

```text
http://<IP_DE_LA_MAQUINA>:32000
```

Kibana ahora **pide inicio de sesión**. Usa una de las cuentas del paso 7.

Si es la primera vez que se configura, crear el Index Pattern:

```text
logstash-*
```

utilizando `@timestamp` como campo de tiempo. 

## 7. Credenciales

| Usuario | Contraseña | Rol |
|---|---|---|
| `elastic` | `Proyecto5Seguro2026!` | Administrador completo (Elasticsearch y Kibana) |
| `auditor` | `Auditor2026Solo!` | Solo lectura sobre `logstash-*` — no puede borrar ni modificar índices |


## 8. Respaldo y retención

- **Retención (ILM):** política `retencion-30-dias` — fase `hot` desde el día 0, fase `delete` a los 30 días. El index template `plantilla-logstash` aplica la política automáticamente a todo índice nuevo `logstash-*`.
- **Respaldo (snapshot):** repositorio `respaldo_local` registrado y snapshot probado con éxito (`"state":"SUCCESS"`, 15/15 shards).

## 9. Dashboards de Kibana

Se importaron 5 dashboards desde `export.ndjson` (junto con el Index Pattern):

| Panel | Contenido |
|---|---|
| 1 — Resumen de seguridad | Barras verticales apiladas · eje horizontal `@timestamp` · eje vertical: conteo de registros + conteo único de `log.tag.keyword` · sin filtro |
| 2 — Auditoría del API Server | Barras verticales apiladas · filtro `log.tag: k8s.audit` · eje horizontal `verb` · desglose por `user.username` |
| 3 — Accesos sensibles | Barras verticales apiladas · filtro `log.tag: k8s.audit AND (objectRef.subresource: "exec" OR objectRef.resource: "secrets" OR objectRef.resource: "roles" OR objectRef.resource: "rolebindings" OR objectRef.resource: "clusterroles" OR objectRef.resource: "clusterrolebindings")` · ejes `user.username` y `objectRef.resource` |
| 4 — Eventos de pods | Barras verticales apiladas · filtro `log.tag: k8s.audit AND objectRef.resource: "pods" AND (verb: "delete" OR verb: "create")` · eje horizontal `@timestamp` · desglose por `verb` |
| 5 — Rechazos y errores | Barras verticales apiladas · filtro `log.tag: k8s.audit AND responseStatus.code >= 400` · eje horizontal `responseStatus.code` (numérico) |


## Estructura

```text
docs/
│
├── 00-namespace.yaml
├── 01-elasticsearch.yaml
├── 02-kibana.yaml
├── 03-eventrouter.yaml
├── 04-fluentd.yaml
├── README.md
├── troubleshooting.md
├── manual-operativo.md
└── installation.md
```
