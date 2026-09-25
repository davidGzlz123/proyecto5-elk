# Solución de problemas — Stack ELK sobre k3s (Proyecto 5)

Guía rápida de los problemas más comunes del stack (Elasticsearch, Kibana, Eventrouter y Fluentd en el namespace `kube-logging`). 


## Índice

| # | Problema |
|---|---|
| [P1](#p1-los-datos-se-pierden-al-reiniciar) | Los datos se pierden al reiniciar |
| [P2](#p2-permisos-del-volumen-de-elasticsearch) | Permisos del volumen de Elasticsearch |
| [P3](#p3-elasticsearch-sin-memoria) | Elasticsearch sin memoria |
| [P4](#p4-disco-lleno-o-índices-en-solo-lectura) | Disco lleno o índices en solo lectura |
| [P5](#p5-campo-de-texto-en-lugar-de-numérico) | Campo de texto en lugar de numérico |
| [P6](#p6-el-certificado-tls-se-corrompe-al-copiarlo-por-terminal) | El certificado TLS se corrompe al copiarlo por terminal |

## Comandos esenciales

```bash
# Estado de los pods
kubectl get pods -n kube-logging

# Por qué falla un pod
kubectl describe pod <POD> -n kube-logging
kubectl logs <POD> -n kube-logging --previous

# Logs de cada componente
kubectl logs -n kube-logging daemonset/fluentd --tail=50
kubectl logs -n kube-logging deployment/kibana --tail=50
kubectl logs -n kube-logging deployment/eventrouter --tail=20

# Salud e índices de Elasticsearch
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cluster/health?pretty"
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices?v"

# Reiniciar un componente
kubectl rollout restart daemonset/fluentd -n kube-logging
```

## P1. Los datos se pierden al reiniciar

**Síntoma:** al reiniciar la VM o recrear el pod, los índices `logstash-*` desaparecen.

**Causa:** Elasticsearch no tenía volumen. Los datos vivían en el sistema de archivos efímero del contenedor, que se descarta al recrearlo.

**Solución:** agregar un PVC de **5Gi** con `local-path` y un `initContainer` para los permisos ([P2](#p2-permisos-del-volumen-de-elasticsearch)). Cambios en el `StatefulSet` de `01-elasticsearch.yaml`:

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
          # ... (imagen, env y ports sin cambios)
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

`volumeClaimTemplates` no se puede modificar en un `StatefulSet` existente, así que hay que recrearlo:

```bash
kubectl delete statefulset elasticsearch -n kube-logging
kubectl apply -f 01-elasticsearch.yaml
```

**Verificación (evidencia de persistencia):**

```bash
kubectl get pvc -n kube-logging        # Bound, 5Gi
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices?v"
kubectl delete pod elasticsearch-0 -n kube-logging      # o: sudo reboot
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices?v"
```

Los mismos índices deben aparecer antes y después.


---

## P2. Permisos del volumen de Elasticsearch

**Síntoma:** tras agregar el volumen, `elasticsearch-0` queda en `CrashLoopBackOff` o `Init:Error`. Los logs muestran:

```
java.nio.file.AccessDeniedException: /usr/share/elasticsearch/data/nodes
failed to obtain node locks ... maybe these locations are not writable
```

**Causa:** el volumen se crea con permisos que Elasticsearch (usuario UID `1000`) no puede escribir por defecto.

**Solución:** el `initContainer` `fix-permissions` de [P1](#p1-los-datos-se-pierden-al-reiniciar) corre como `root` antes de Elasticsearch y ejecuta `chown -R 1000:1000` sobre la carpeta de datos.

```bash
kubectl logs elasticsearch-0 -n kube-logging -c fix-permissions     # log del initContainer
kubectl logs elasticsearch-0 -n kube-logging -c elasticsearch       # log de Elasticsearch
kubectl exec -n kube-logging elasticsearch-0 -- ls -ld /usr/share/elasticsearch/data
```


---

## P3. Elasticsearch sin memoria

**Síntoma:** `elasticsearch-0` se reinicia; `describe pod` muestra `Reason: OOMKilled`, `Exit Code: 137`.

**Causa:** sin límites de memoria ni heap definido, la JVM compite por los 7.3 GB de la VM con k3s y Kibana.

**Solución:** fijar heap y recursos en el contenedor (el heap debe ser como máximo la mitad del límite):

```yaml
          env:
            - name: discovery.type
              value: single-node
            - name: ES_JAVA_OPTS
              value: "-Xms1g -Xmx1g"
          resources:
            requests:
              memory: 2Gi
            limits:
              memory: 2Gi
```

```bash
kubectl apply -f 01-elasticsearch.yaml
kubectl rollout restart statefulset/elasticsearch -n kube-logging
free -h        # en el nodo
```

---

## P4. Disco lleno o índices en solo lectura

**Síntoma:** Fluentd muestra `read-only-allow-delete block` o `cluster_block_exception`; Discover deja de recibir datos.

**Causa:** con más del 95 % de disco usado, Elasticsearch marca los índices como solo lectura. Sin política de retención, los índices diarios se acumulan. El provisionador `local-path` normalmente no hace cumplir los 5Gi del PVC: Elasticsearch mide el disco del nodo.

**Solución:**

```bash
# 1. Ver uso de disco y tamaño por día
df -h /var/lib/rancher/k3s
kubectl exec -n kube-logging elasticsearch-0 -- curl -s "http://localhost:9200/_cat/indices/logstash-*?v&h=index,store.size&s=index"

# 2. Exportar la evidencia necesaria y borrar índices antiguos (con aprobación)
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -X DELETE "http://localhost:9200/logstash-AAAA.MM.DD"

# 3. Quitar el bloqueo de solo lectura
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -X PUT "http://localhost:9200/logstash-*/_settings" \
  -H 'Content-Type: application/json' -d '{"index.blocks.read_only_allow_delete": null}'

# 4. Reiniciar Fluentd
kubectl rollout restart daemonset/fluentd -n kube-logging
```

**Prevención (retención automática).** En Kibana → Dev Tools (ajusta `30d` a tu política):

```
PUT _ilm/policy/retencion-logs
{ "policy": { "phases": { "delete": { "min_age": "30d", "actions": { "delete": {} } } } } }

PUT logstash-*/_settings
{ "index.lifecycle.name": "retencion-logs" }
```

Para los índices nuevos, agrega `"index.lifecycle.name": "retencion-logs"` en los `settings` de la plantilla de [P8](#p8-campo-de-texto-en-lugar-de-numérico).

---

## P5 Campo de texto en lugar de numérico

**Síntoma:** en el Index Pattern un campo (por ejemplo `duration`) aparece como **`conflict`**; no se puede sumar o promediar; error `Fielddata is disabled on text fields`.

**Causa:** Elasticsearch fija el tipo de un campo con el primer documento y el stack crea un índice nuevo cada día. Si un día llega `"120"` (texto) y otro `120` (número), el tipo difiere entre índices. Lo que va dentro de `message` es siempre texto.

**Solución:**

```
# 1. Ver el tipo del campo en cada índice (Kibana → Dev Tools)
GET logstash-*/_mapping/field/duration

# 2. Fijar los tipos con una plantilla (aplica solo a índices nuevos)
PUT _index_template/logstash-tpl
{
  "index_patterns": ["logstash-*"],
  "priority": 100,
  "template": {
    "settings": { "number_of_replicas": 0 },
    "mappings": {
      "properties": {
        "status_code": { "type": "integer" },
        "duration":    { "type": "float" }
      }
    }
  }
}

# 3. Corregir un índice ya creado: reindexar a un índice nuevo
POST _reindex
{ "source": { "index": "logstash-2026.09.21" }, "dest": { "index": "logstash-2026.09.21-fix" } }
```

Revisa `failures` en la respuesta del reindex. Tras exportar la evidencia necesaria, borra el índice original (`DELETE logstash-2026.09.21`). Después, en Kibana: *Stack Management → Index Patterns → `logstash-*` → Refresh field list*.

Los campos `status_code` y `duration` son ejemplos: usa los de tu proyecto.

**Búsquedas en KQL:** para ordenar, agrupar o usar comodines en texto, usa el subcampo `.keyword` (`log.tag.keyword : *eventrouter*`). Para buscar una palabra usa `message : "BackOff"`, no `message : *BackOff*`.

**Eventos de Eventrouter como texto:** llegan como JSON dentro de `message`. Para separarlos en campos, agrega en `fluent.conf` entre `<source>` y `<match>`, y reinicia Fluentd:

```
<filter kubernetes.**>
  @type parser
  key_name message
  reserve_data true
  emit_invalid_record_to_error false
  <parse>
    @type json
  </parse>
</filter>
```

## P12. El certificado TLS se corrompe al copiarlo por terminal

**Síntoma:** al activar TLS (por ejemplo, seguridad en Elasticsearch o un `Secret` de tipo `tls`), el certificado o la clave no cargan. Error típico:

```
base64: invalid input
error: error parsing ...: illegal base64 data at input byte ...
Failed to load SSL certificate ... PEM_read_bio failed
```

**Causa:** el certificado (`.crt`/`.pem`) o la clave (`.key`) se dañan al pasar por la terminal antes de llegar al clúster. Las causas más comunes:

- Copiar y pegar el contenido en una terminal SSH: se pierden saltos de línea, o el cliente de la terminal cambia espacios por tabulaciones.
- Usar `cat certificado.crt` para copiar el texto visualmente en lugar de transferir el archivo.
- Generar el `Secret` a mano (YAML con el certificado ya en base64 escrito por alguien) en lugar de dejar que `kubectl` lo codifique.
- Editar el archivo con un editor que cambia el fin de línea (CRLF de Windows en vez de LF de Linux) o que agrega una línea en blanco al final.


**Solución.** No copies y pegues el contenido del certificado: transfiere el **archivo** y deja que `kubectl` haga la codificación.

```bash
# 1. Transferir el archivo sin pasar por copiar/pegar en la terminal
scp certificado.crt clave.key usuario@<IP_DE_LA_MAQUINA>:~/

# 2. Verificar que el archivo no esté dañado ANTES de usarlo
openssl x509 -in certificado.crt -noout -text   # debe mostrar el certificado, sin errores
file certificado.crt                            # debe decir "PEM certificate", no "ASCII text" genérico
cat -A certificado.crt | head -3                 # ^M al final de línea = CRLF de Windows (problema)

# 3. Si tiene CRLF, convertir a LF
sed -i 's/\r$//' certificado.crt

# 4. Dejar que kubectl codifique el archivo (nunca pegar el base64 a mano)
kubectl create secret tls mi-tls \
  --cert=certificado.crt --key=clave.key \
  -n kube-logging
```

**Si el `Secret` ya existe y quieres verificarlo o recrearlo:**

```bash
# Verificar que el base64 guardado sea válido y coincida con el archivo original
kubectl get secret mi-tls -n kube-logging -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text

# Si falla, borrar y recrear con el archivo (no editar el Secret a mano)
kubectl delete secret mi-tls -n kube-logging
kubectl create secret tls mi-tls --cert=certificado.crt --key=clave.key -n kube-logging
```

**Verificación.** `openssl x509 -in certificado.crt -noout -text` no da error, y `kubectl get secret mi-tls -n kube-logging -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text` muestra el mismo certificado.