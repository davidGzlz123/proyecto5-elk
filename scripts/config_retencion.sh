#!/bin/bash

echo "Configurando politica de retencion de 30 dias en Elasticsearch..."
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -X PUT "http://localhost:9200/_ilm/policy/retencion-30-dias" -H 'Content-Type: application/json' -d'
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "set_priority": {
            "priority": 100
          }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}'

echo -e "\n\nAplicando politica a los nuevos indices..."
kubectl exec -n kube-logging elasticsearch-0 -- curl -s -X PUT "http://localhost:9200/_index_template/plantilla-logstash" -H 'Content-Type: application/json' -d'
{
  "index_patterns": ["logstash-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "retencion-30-dias"
    }
  }
}'

echo -e "\n\n¡Configuracion completada con exito!"
