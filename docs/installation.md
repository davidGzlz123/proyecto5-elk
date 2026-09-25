# Guía de Instalación y Despliegue — ELK Stack (Proyecto 5)

Esta guía detalla, paso a paso, cómo levantar un entorno completo de recolección y centralización de eventos y logs sobre un clúster de Kubernetes con k3s, usando Elasticsearch (clúster de 3 nodos, con TLS y seguridad), Kibana, Eventrouter y Fluentd**. Cumple con los requisitos del Proyecto 5 para la centralización de evidencia.

## Índice

1. [Namespace](#1-namespace)
2. [Elasticsearch](#2-elasticsearch)
3. [Kibana](#3-kibana)
4. [Eventrouter](#4-eventrouter)
5. [Fluentd](#5-fluentd)
6. [Habilitar el audit log del API Server](#6-habilitar-el-audit-log-del-api-server)
7. [Fluentd también lee el audit log](#7-fluentd-también-lee-el-audit-log)
8. [Volumen persistente de Elasticsearch](#8-volumen-persistente-de-elasticsearch)
9. [Retención de índices (ILM)](#9-retención-de-índices-ilm)
10. [Importar los dashboards en Kibana](#10-importar-los-dashboards-en-kibana)
11. [Generar eventos de prueba](#11-generar-eventos-de-prueba)
12. [Verificar la sincronización de reloj (NTP)](#12-verificar-la-sincronización-de-reloj-ntp)
13. [Activar seguridad en Elasticsearch](#13-activar-seguridad-en-elasticsearch)
14. [Crear el rol y el usuario de solo lectura](#14-crear-el-rol-y-el-usuario-de-solo-lectura)
15. [Registrar el repositorio de respaldo y tomar un snapshot](#15-registrar-el-repositorio-de-respaldo-y-tomar-un-snapshot)
16. [Generar los certificados TLS](#16-generar-los-certificados-tls)
17. [Elasticsearch como clúster de 3 nodos con TLS](#17-elasticsearch-como-clúster-de-3-nodos-con-tls)
18. [Exportar los dashboards de Kibana](#18-exportar-los-dashboards-de-kibana)
19. [Validación final](#19-validación-final)

---

## Prerrequisitos del sistema

Máquina virtual (o servidor) con las siguientes características:

| Requisito | Mínimo recomendado |
|---|---|
| Sistema operativo | Ubuntu Server 20.04 LTS o superior |
| CPU | 2 vCPUs |
| Memoria RAM | 7.3 GB — el clúster de 3 nodos de Elasticsearch, con seguridad y TLS activados, necesita bastante más que un solo nodo |
| Almacenamiento | 20 GB de disco libre, más 5 GB por cada uno de los 3 nodos de Elasticsearch (volumen persistente) |
| Software | k3s instalado y funcionando, con `kubectl` apuntando al clúster local |

Verifica que el clúster esté listo antes de continuar:

```bash
kubectl get nodes
```

El nodo debe aparecer en estado `Ready`.

---

## 1. Namespace

Primero se crea el espacio de nombres aislado donde vivirán todas las herramientas de recolección.

Crea el archivo `00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-logging
```

Aplica el archivo:

```bash
kubectl apply -f 00-namespace.yaml
kubectl get namespace kube-logging
```

---

## 2. Elasticsearch

Elasticsearch es el motor de almacenamiento de evidencia. Se despliega como `StatefulSet` de un solo nodo por ahora (`discovery.type=single-node`); en la sección 17 se amplía a 3 nodos con TLS.

Crea el archivo `01-elasticsearch.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: kube-logging
  labels:
    app: elasticsearch
spec:
  ports:
    - port: 9200
      name: rest
  clusterIP: None
  selector:
    app: elasticsearch
---
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
```

Aplica el archivo y espera a que el pod esté en estado `Running`:

```bash
kubectl apply -f 01-elasticsearch.yaml
kubectl get pods -n kube-logging -w
```

---

## 3. Kibana

Kibana es la interfaz para visualizar los dashboards y buscar eventos. Se expone al exterior mediante un `Service` de tipo `NodePort` en el puerto `32000`.

Crea el archivo `02-kibana.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: kube-logging
  labels:
    app: kibana
spec:
  type: NodePort
  ports:
    - port: 5601
      targetPort: 5601
      nodePort: 32000
  selector:
    app: kibana
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: kube-logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kibana
  template:
    metadata:
      labels:
        app: kibana
    spec:
      containers:
        - name: kibana
          image: docker.elastic.co/kibana/kibana:7.17.10
          env:
            - name: ELASTICSEARCH_HOSTS
              value: http://elasticsearch.kube-logging.svc.cluster.local:9200
          ports:
            - containerPort: 5601
```

Aplica el archivo:

```bash
kubectl apply -f 02-kibana.yaml
```

---

## 4. Eventrouter

Eventrouter intercepta los eventos del plano de control del clúster con un RBAC de solo lectura sobre `events`, y los manda a la salida estándar (`stdout`) para que Fluentd los recolecte junto con el resto de los logs.

Crea el archivo `03-eventrouter.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eventrouter
  namespace: kube-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: eventrouter
rules:
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: eventrouter
  namespace: kube-logging
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: eventrouter
subjects:
  - kind: ServiceAccount
    name: eventrouter
    namespace: kube-logging
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eventrouter
  namespace: kube-logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: eventrouter
  template:
    metadata:
      labels:
        app: eventrouter
    spec:
      serviceAccountName: eventrouter
      containers:
        - name: kube-eventrouter
          image: gcr.io/heptio-images/eventrouter:v0.3
          imagePullPolicy: IfNotPresent
          env:
            - name: KUBE_API_VERSIONS
              value: ""
          volumeMounts:
            - name: config-volume
              mountPath: /etc/eventrouter
      volumes:
        - name: config-volume
          configMap:
            name: eventrouter-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: eventrouter-config
  namespace: kube-logging
data:
  config.json: |-
    {
      "sink": "stdout"
    }
```

Aplica el archivo:

```bash
kubectl apply -f 03-eventrouter.yaml
```

Verifica que esté emitiendo eventos por la salida estándar:

```bash
kubectl logs -n kube-logging deployment/eventrouter --tail=5
```

---

## 5. Fluentd

Fluentd corre como `DaemonSet` para recolectar los logs de los nodos desde `/var/log/containers/*.log`. Está configurado para correr como **root** e instala el plugin parser CRI, necesario para leer el formato de logs de los contenedores en k3s.

Crea el archivo `04-fluentd.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: kube-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentd-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentd
subjects:
  - kind: ServiceAccount
    name: fluentd
    namespace: kube-logging
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: kube-logging
data:
  fluent.conf: |
    <source>
      @type tail
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type cri
      </parse>
    </source>

    <match kubernetes.**>
      @type elasticsearch
      host elasticsearch.kube-logging.svc.cluster.local
      port 9200
      logstash_format true
      include_tag_key true
      tag_key log.tag
      <buffer>
        flush_interval 5s
      </buffer>
    </match>
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: kube-logging
  labels:
    app: fluentd
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      serviceAccount: fluentd
      tolerations:
        - operator: Exists
          effect: NoSchedule
      containers:
        - name: fluentd
          image: fluent/fluentd:v1.16-debian
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsUser: 0
          command: ["/bin/sh", "-c"]
          args:
            - gem install elasticsearch -v 7.17.0 --no-document && gem install fluent-plugin-elasticsearch -v 5.3.0 --no-document && gem install fluent-plugin-parser-cri --no-document && fluentd -c /fluentd/etc/fluent.conf
          volumeMounts:
            - name: config-volume
              mountPath: /fluentd/etc/
            - name: varlog
              mountPath: /var/log
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
      volumes:
        - name: config-volume
          configMap:
            name: fluentd-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
```

Aplica el archivo:

```bash
kubectl apply -f 04-fluentd.yaml
```

Confirma que hasta aquí el flujo básico funciona:

```bash
kubectl get pods -n kube-logging
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices?v"
```

Debe aparecer un índice `logstash-YYYY.MM.DD`. Accede a Kibana en `http://<IP_DE_LA_MAQUINA>:32000` y crea el Index Pattern `logstash-*` con el campo de tiempo `@timestamp`.

---

## 6. Habilitar el audit log del API Server

El audit log del API Server es una de las fuentes de log del proyecto. Se habilita a nivel del sistema operativo, en la configuración de k3s.

En el nodo (con `sudo`), crea una política de auditoría mínima en `/var/lib/rancher/k3s/server/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
```

Edita el archivo de configuración de k3s (por ejemplo, `/etc/systemd/system/k3s.service`) para agregar los argumentos del API Server:

```
--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit.log
--kube-apiserver-arg=audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml
--kube-apiserver-arg=audit-log-maxage=30
--kube-apiserver-arg=audit-log-maxbackup=10
```

Aplica los cambios y verifica:

```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
sudo ls -lh /var/log/kubernetes/audit.log
sudo tail -5 /var/log/kubernetes/audit.log
```

---

## 7. Fluentd también lee el audit log

Se agrega una fuente al `ConfigMap` `fluentd-config` para que Fluentd también lea `/var/log/kubernetes/audit.log`, con el tag `k8s.audit`.

Edita `04-fluentd.yaml` y agrega, dentro de `data.fluent.conf`, esta fuente y su salida (el resto del archivo no cambia):

```yaml
    <source>
      @type tail
      path /var/log/kubernetes/audit.log
      pos_file /var/log/fluentd-audit.log.pos
      tag k8s.audit
      read_from_head true
      <parse>
        @type json
      </parse>
    </source>

    <match k8s.audit>
      @type elasticsearch
      host elasticsearch.kube-logging.svc.cluster.local
      port 9200
      logstash_format true
      logstash_prefix logstash
      include_tag_key true
      tag_key log.tag
      <buffer>
        flush_interval 5s
      </buffer>
    </match>
```

Aplica el `ConfigMap` actualizado y reinicia Fluentd:

```bash
kubectl apply -f 04-fluentd.yaml
kubectl rollout restart daemonset/fluentd -n kube-logging
```

---

## 8. Volumen persistente de Elasticsearch

Se agrega un volumen persistente de **5Gi** (`storageClassName: local-path`) para que los índices sobrevivan a un reinicio del pod o de la VM. El volumen se crea con permisos que Elasticsearch (usuario UID `1000`) no puede escribir por defecto, así que se incluye un `initContainer` que corrige el dueño de la carpeta de datos antes de que arranque Elasticsearch.

Agrega `initContainers` y `volumeMounts` a la plantilla del `StatefulSet`, y `volumeClaimTemplates` al final, en `01-elasticsearch.yaml`:

```yaml
    spec:
      initContainers:
        - name: fix-permissions
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          securityContext:
            runAsUser: 0
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
```

`volumeClaimTemplates` es un campo inmutable en un `StatefulSet`, así que para aplicarlo hay que recrearlo (el `Service` no cambia):

```bash
kubectl delete statefulset elasticsearch -n kube-logging
kubectl apply -f 01-elasticsearch.yaml
kubectl get pods -n kube-logging -w
```

Verifica los permisos y que el pod quede sano:

```bash
kubectl exec -n kube-logging elasticsearch-0 -- ls -ld /usr/share/elasticsearch/data
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices?v"
```

---

## 9. Retención de índices (ILM)

Se define una política de ciclo de vida para que los índices se retengan **30 días**, con fase `hot` desde el día 0 y borrado al cumplirse el plazo, y una plantilla para que se aplique automáticamente a todo índice nuevo `logstash-*`.

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s \
  -X PUT "http://localhost:9200/_ilm/policy/retencion-30-dias" \
  -H 'Content-Type: application/json' -d '{
    "policy": {
      "phases": {
        "hot":    { "min_age": "0ms", "actions": {} },
        "delete": { "min_age": "30d", "actions": { "delete": {} } }
      }
    }
  }'

kubectl exec -n kube-logging elasticsearch-0 -- curl -s \
  -X PUT "http://localhost:9200/_index_template/plantilla-logstash" \
  -H 'Content-Type: application/json' -d '{
    "index_patterns": ["logstash-*"],
    "priority": 100,
    "template": {
      "settings": { "index.lifecycle.name": "retencion-30-dias" }
    }
  }'
```

---

## 10. Importar los dashboards en Kibana

Se restauran 5 dashboards y el Index Pattern desde un archivo `export.ndjson` preparado para el proyecto.

1. Abre Kibana en `http://<IP_DE_LA_MAQUINA>:32000`.
2. Ve a **Stack Management → Saved Objects → Import**.
3. Selecciona el archivo `export.ndjson`.
4. Si pregunta por conflictos con objetos existentes, usa **Overwrite** para reemplazarlos por la versión del archivo.
5. Confirma que aparezcan el Index Pattern `logstash-*` y los 5 dashboards en el listado de Saved Objects.

---

## 11. Generar eventos de prueba

Para que los dashboards importados tengan datos que mostrar, se genera actividad real en el clúster:

```bash
#!/bin/bash
kubectl run prueba-ok --image=busybox --restart=Never -- echo "evento de prueba OK"
kubectl create deployment prueba-imagen-mala --image=imagen-que-no-existe
sleep 30
kubectl delete pod prueba-ok
kubectl delete deployment prueba-imagen-mala
```

Verifica en Kibana → Discover que los eventos (`ImagePullBackOff`, creación/eliminación de pods) aparecen en los índices `logstash-*`.

---

## 12. Verificar la sincronización de reloj (NTP)

Corresponde al control A.8.17. Se verifica que el reloj del nodo esté sincronizado, necesario para poder correlacionar eventos de distintas fuentes:

```bash
timedatectl status
```

Debe indicar `System clock synchronized: yes` y `NTP service: active`.

---

## 13. Activar seguridad en Elasticsearch

Se habilita `xpack.security.enabled: true`, se define el usuario administrador `elastic` y se agrega `path.repo` (usado en la sección 15 para el respaldo). Kibana y Fluentd se actualizan para autenticarse con esas credenciales.

Agrega al bloque `env` del contenedor `elasticsearch` en `01-elasticsearch.yaml`:

```yaml
            - name: xpack.security.enabled
              value: "true"
            - name: path.repo
              value: /usr/share/elasticsearch/data/backup
            - name: ELASTIC_PASSWORD
              value: "Proyecto5Seguro2026!"
```

`path.repo` queda dentro de `/usr/share/elasticsearch/data`, la misma ruta donde ya está montado el volumen persistente `data` (sección 8): así el snapshot sobrevive si el pod se recrea. No hace falta agregar ningún volumen adicional para el respaldo; el `initContainer` `fix-permissions` ya corrige los permisos de esa ruta de forma recursiva, y Elasticsearch crea la subcarpeta `backup` la primera vez que la necesita.

```bash
kubectl apply -f 01-elasticsearch.yaml
kubectl rollout restart statefulset/elasticsearch -n kube-logging
```

Actualiza Kibana (`02-kibana.yaml`) para autenticarse:

```yaml
            - name: ELASTICSEARCH_USERNAME
              value: elastic
            - name: ELASTICSEARCH_PASSWORD
              value: "Proyecto5Seguro2026!"
```

```bash
kubectl apply -f 02-kibana.yaml
```

Actualiza Fluentd (`04-fluentd.yaml`): agrega la variable de entorno al contenedor y las credenciales en los dos bloques `<match>`:

```yaml
          env:
            - name: ELASTIC_PASSWORD
              value: "Proyecto5Seguro2026!"
```

```yaml
      user elastic
      password "#{ENV['ELASTIC_PASSWORD']}"
```

```bash
kubectl apply -f 04-fluentd.yaml
kubectl rollout restart daemonset/fluentd -n kube-logging
```

Verifica que Elasticsearch ahora pida autenticación, y que Kibana pida inicio de sesión al abrir `http://<IP_DE_LA_MAQUINA>:32000`:

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  "http://localhost:9200/_cluster/health?pretty"
```

---

## 14. Crear el rol y el usuario de solo lectura

Refuerza A.8.15: un usuario que puede consultar la evidencia pero no alterarla ni borrarla.

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  -X POST "http://localhost:9200/_security/role/solo_lectura" \
  -H 'Content-Type: application/json' -d '{
    "indices": [
      { "names": ["logstash-*"], "privileges": ["read", "view_index_metadata"] }
    ]
  }'

kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  -X POST "http://localhost:9200/_security/user/auditor" \
  -H 'Content-Type: application/json' -d '{
    "password": "Auditor2026Solo!",
    "roles": ["solo_lectura"]
  }'
```

Verifica que `auditor` no pueda borrar un índice (debe responder `403`):

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -o /dev/null -w "%{http_code}\n" \
  -u auditor:Auditor2026Solo! -X DELETE "http://localhost:9200/logstash-2026.09.21"
```

---

## 15. Registrar el repositorio de respaldo y tomar un snapshot

Corresponde a A.8.13. Usa la ruta `path.repo` habilitada en la sección 13.

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  -X PUT "http://localhost:9200/_snapshot/respaldo_local" \
  -H 'Content-Type: application/json' -d '{
    "type": "fs",
    "settings": { "location": "/usr/share/elasticsearch/data/backup" }
  }'

kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  -X PUT "http://localhost:9200/_snapshot/respaldo_local/snapshot-inicial?wait_for_completion=true" \
  -H 'Content-Type: application/json' -d '{ "indices": "logstash-*" }'
```

Verifica que el resultado indique `"state":"SUCCESS"`:

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  "http://localhost:9200/_snapshot/respaldo_local/snapshot-inicial?pretty"
```

---

## 16. Generar los certificados TLS

Elasticsearch necesita un certificado compartido para cifrar el tráfico **entre nodos** (`xpack.security.transport.ssl`), que se usará en el clúster de 3 nodos de la sección 17.

Como el certificado es un archivo binario, se genera dentro de un pod temporal y se extrae con `kubectl cp`, en vez de copiarlo o pegarlo como texto en la terminal (lo que corrompería el archivo y produciría errores como `base64: invalid input`).

Genera la CA y el certificado en un pod temporal, con la propia imagen de Elasticsearch:

```bash
kubectl run cert-gen -n kube-logging --restart=Never \
  --image=docker.elastic.co/elasticsearch/elasticsearch:7.17.10 \
  --command -- /bin/sh -c "elasticsearch-certutil ca --out /tmp/elastic-stack-ca.p12 --pass '' && \
    elasticsearch-certutil cert --ca /tmp/elastic-stack-ca.p12 --ca-pass '' \
    --out /tmp/elastic-certificates.p12 --pass '' && sleep 3600"

kubectl wait --for=condition=Ready pod/cert-gen -n kube-logging --timeout=120s
```

Copia el `.p12` fuera del pod:

```bash
kubectl cp kube-logging/cert-gen:/tmp/elastic-certificates.p12 ./elastic-certificates.p12
kubectl delete pod cert-gen -n kube-logging
```

Extrae la CA, el certificado y la llave en formato PEM:

```bash
openssl pkcs12 -in elastic-certificates.p12 -clcerts -nokeys -out elastic-certificate.pem -passin pass:
openssl pkcs12 -in elastic-certificates.p12 -nocerts -nodes -out elastic-certificate.key -passin pass:
openssl pkcs12 -in elastic-certificates.p12 -cacerts -nokeys -chain -out elastic-ca.pem -passin pass:
```

Crea el `Secret` a partir de los archivos (`kubectl` se encarga de codificarlos correctamente; no se pega el contenido a mano):

```bash
kubectl create secret generic elastic-certificates \
  --from-file=elastic-certificate.pem \
  --from-file=elastic-certificate.key \
  --from-file=elastic-ca.pem \
  -n kube-logging
```

---

## 17. Elasticsearch como clúster de 3 nodos con TLS

Se amplía Elasticsearch a un `StatefulSet` de **3 réplicas** (`elasticsearch-0`, `elasticsearch-1`, `elasticsearch-2`), con TLS entre nodos usando el `Secret` `elastic-certificates` de la sección 16 y descubrimiento vía `discovery.seed_hosts`.

Reemplaza por completo `01-elasticsearch.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: kube-logging
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
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: kube-logging
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
          image: busybox:1.36
          command: ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:7.17.10
          env:
            - name: node.name
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: cluster.name
              value: proyecto5-logging
            - name: discovery.seed_hosts
              value: "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
            - name: cluster.initial_master_nodes
              value: "elasticsearch-0,elasticsearch-1,elasticsearch-2"
            - name: xpack.security.enabled
              value: "true"
            - name: xpack.security.transport.ssl.enabled
              value: "true"
            - name: xpack.security.transport.ssl.verification_mode
              value: certificate
            - name: xpack.security.transport.ssl.certificate
              value: /usr/share/elasticsearch/config/certs/elastic-certificate.pem
            - name: xpack.security.transport.ssl.key
              value: /usr/share/elasticsearch/config/certs/elastic-certificate.key
            - name: xpack.security.transport.ssl.certificate_authorities
              value: /usr/share/elasticsearch/config/certs/elastic-ca.pem
            - name: path.repo
              value: /usr/share/elasticsearch/data/backup
            - name: ELASTIC_PASSWORD
              value: "Proyecto5Seguro2026!"
          ports:
            - containerPort: 9200
              name: rest
              protocol: TCP
            - containerPort: 9300
              name: transport
              protocol: TCP
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
```

Al pasar de 1 a 3 réplicas hay que recrear el `StatefulSet` (el `Service` no cambia):

```bash
kubectl delete statefulset elasticsearch -n kube-logging
kubectl apply -f 01-elasticsearch.yaml
kubectl get pods -n kube-logging -w
```

Verifica la salud del clúster (debe mostrar `"status": "green"`, `"number_of_nodes": 3`, `"active_shards_percent_as_number": 100.0`):

```bash
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  "http://localhost:9200/_cluster/health?pretty"
```

Como el `StatefulSet` se recreó, confirma que la política de retención (sección 9) y el usuario `auditor` (sección 14) sigan existiendo; si no, vuelve a crearlos con los mismos comandos.

---

## 18. Exportar los dashboards de Kibana

Se guarda un respaldo de los dashboards y el Index Pattern, listo para restaurarse si el entorno se reconstruye.

1. En Kibana, ve a **Stack Management → Saved Objects**.
2. Selecciona el Index Pattern `logstash-*` y los 5 dashboards.
3. Usa **Export** para generar un `export.ndjson`.
4. Guarda ese archivo junto al resto de la evidencia del proyecto.

---

## 19. Validación final

```bash
kubectl get pods -n kube-logging
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -u elastic:Proyecto5Seguro2026! \
  "http://localhost:9200/_cat/indices?v"
```

Si aparece un índice con el patrón `logstash-YYYY.MM.DD`, el entorno está listo.

Accede a Kibana desde el navegador en `http://<IP_DE_LA_MAQUINA>:32000`. Pedirá inicio de sesión: usa el usuario `elastic` (administración completa) o `auditor` (solo lectura).

---
