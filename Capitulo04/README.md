# Implementar ELK/EFK y Jaeger para Trazabilidad

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Visión General

En este laboratorio se construirá una infraestructura completa de logging y trazabilidad distribuida sobre el clúster `lab-calico`. Se desplegará el stack EFK (Elasticsearch + Fluentd + Kibana) para recolección centralizada de logs, Jaeger con Elasticsearch como backend para trazas distribuidas, y se instrumentará la aplicación `webapp` con OpenTelemetry para emitir trazas correlacionadas con los logs mediante W3C TraceContext.

## Objetivos de Aprendizaje

- [ ] Desplegar Elasticsearch 8.14.1 en modo single-node con almacenamiento persistente y Kibana 8.14.1 para visualización de logs
- [ ] Configurar Fluentd 1.17.0 como DaemonSet con parsers y filtros de enriquecimiento de metadatos Kubernetes
- [ ] Desplegar Jaeger 1.58.0 con el Jaeger Operator usando Elasticsearch como backend de almacenamiento
- [ ] Instrumentar la aplicación `webapp` con OpenTelemetry Collector 0.103.0 como sidecar para captura y propagación de trazas
- [ ] Implementar correlación logs-trazas mediante trace-id propagation visible en Kibana y Jaeger UI

## Prerrequisitos

### Conocimientos

- Familiaridad con DaemonSets, StatefulSets y Services en Kubernetes
- Comprensión de los modelos de logging a nivel de nodo (lección 4.1)
- Conceptos básicos de trazabilidad distribuida (spans, traces, propagación de contexto)

### Acceso y Estado del Clúster

- Lab 01 completado: clúster `lab-calico` operativo con contexto `kind-lab-calico`
- Lab 02 completado: aplicación `webapp` desplegada en namespace `webapp`
- cert-manager instalado en namespace `cert-manager`
- Helm repos configurados: `elastic`, `jaegertracing`, `open-telemetry`
- `vm.max_map_count=262144` configurado en los nodos (requerido por Elasticsearch)
- StorageClass `standard` disponible en el clúster

## Entorno del Laboratorio

### Software Requerido

| Componente | Versión |
|------------|---------|
| Elasticsearch | 8.14.1 |
| Kibana | 8.14.1 |
| Fluentd | 1.17.0 |
| Jaeger / Jaeger Operator | 1.58.0 |
| OpenTelemetry Collector | 0.103.0 |
| Helm | 3.15.2 |
| kubectl | 1.30.2 |

### Preparación Inicial

```bash
# Verificar contexto del clúster
kubectl config use-context kind-lab-calico

# Crear directorio de trabajo
mkdir -p ~/k8s-labs/lab04
cd ~/k8s-labs/lab04

# Crear namespace logging
kubectl create namespace logging

# Verificar que vm.max_map_count está configurado en los nodos kind
for node in $(kind get nodes --name lab-calico); do
  docker exec $node sysctl -w vm.max_map_count=262144
done

# Verificar Helm repos
helm repo add elastic https://helm.elastic.co 2>/dev/null || true
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update
```

---

## Paso 1: Desplegar Elasticsearch 8.14.1

### Objetivo

Instalar Elasticsearch en modo single-node dentro del namespace `logging` con almacenamiento persistente de 10Gi y seguridad básica habilitada.

### Instrucciones

1. Crear el fichero de valores para Helm:

```bash
cat > ~/k8s-labs/lab04/elasticsearch-values.yaml << 'EOF'
replicas: 1
minimumMasterNodes: 1

image: "docker.elastic.co/elasticsearch/elasticsearch"
imageTag: "8.14.1"

# Modo single-node
clusterHealthCheckParams: "wait_for_status=yellow&timeout=1s"

esConfig:
  elasticsearch.yml: |
    cluster.name: "lab-logging"
    network.host: 0.0.0.0
    discovery.type: single-node
    xpack.security.enabled: true
    xpack.security.http.ssl.enabled: false
    xpack.security.transport.ssl.enabled: false

# Recursos para entorno kind
resources:
  requests:
    cpu: "500m"
    memory: "2Gi"
  limits:
    cpu: "2000m"
    memory: "4Gi"

volumeClaimTemplate:
  accessModes: ["ReadWriteOnce"]
  storageClassName: "standard"
  resources:
    requests:
      storage: 10Gi

# Variables de entorno para credenciales
extraEnvs:
  - name: ELASTIC_PASSWORD
    value: "ElasticK8s2024!"
  - name: xpack.security.enabled
    value: "true"

# Deshabilitar antiaffinity para single-node en kind
antiAffinity: "soft"

# Service
service:
  type: ClusterIP
  httpPortName: http
  transportPortName: transport

# Pod Security Context
podSecurityContext:
  fsGroup: 1000
  runAsUser: 1000

securityContext:
  capabilities:
    drop:
      - ALL
  runAsNonRoot: true
  runAsUser: 1000

# Readiness probe ajustada
readinessProbe:
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 5

protocol: http
EOF
```

2. Instalar Elasticsearch con Helm:

```bash
helm install elasticsearch elastic/elasticsearch \
  --namespace logging \
  --values ~/k8s-labs/lab04/elasticsearch-values.yaml \
  --version 8.5.1 \
  --wait --timeout 5m
```

3. Esperar a que el pod esté listo:

```bash
kubectl wait --for=condition=ready pod/elasticsearch-master-0 \
  --namespace logging --timeout=300s
```

### Salida Esperada

```
pod/elasticsearch-master-0 condition met
```

### Verificación

```bash
# Verificar estado del clúster Elasticsearch
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! http://localhost:9200/_cluster/health | \
  python3 -m json.tool
```

Debe mostrar `"status": "green"` o `"yellow"` con `"number_of_nodes": 1`.

---

## Paso 2: Desplegar Kibana 8.14.1

### Objetivo

Instalar Kibana conectado a Elasticsearch para visualización de logs y configurar acceso mediante port-forward.

### Instrucciones

1. Crear el fichero de valores para Kibana:

```bash
cat > ~/k8s-labs/lab04/kibana-values.yaml << 'EOF'
image: "docker.elastic.co/kibana/kibana"
imageTag: "8.14.1"

elasticsearchHosts: "http://elasticsearch-master:9200"

extraEnvs:
  - name: ELASTICSEARCH_USERNAME
    value: "elastic"
  - name: ELASTICSEARCH_PASSWORD
    value: "ElasticK8s2024!"
  - name: SERVER_BASEPATH
    value: ""

resources:
  requests:
    cpu: "250m"
    memory: "1Gi"
  limits:
    cpu: "1000m"
    memory: "2Gi"

service:
  type: ClusterIP
  port: 5601

readinessProbe:
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 10

healthCheckPath: "/api/status"

kibanaConfig:
  kibana.yml: |
    server.host: "0.0.0.0"
    elasticsearch.hosts: ["http://elasticsearch-master:9200"]
    elasticsearch.username: "elastic"
    elasticsearch.password: "ElasticK8s2024!"
    monitoring.ui.enabled: false
EOF
```

2. Instalar Kibana:

```bash
helm install kibana elastic/kibana \
  --namespace logging \
  --values ~/k8s-labs/lab04/kibana-values.yaml \
  --version 8.5.1 \
  --wait --timeout 5m
```

3. Verificar que Kibana está listo:

```bash
kubectl wait --for=condition=ready pod -l app=kibana \
  --namespace logging --timeout=300s
```

### Salida Esperada

```
pod/kibana-kibana-<hash> condition met
```

### Verificación

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! http://kibana-kibana:5601/api/status | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Kibana status: {d[\"status\"][\"overall\"][\"level\"]}')"
```

Debe mostrar: `Kibana status: available`

---

## Paso 3: Desplegar Fluentd como DaemonSet

### Objetivo

Configurar Fluentd 1.17.0 como DaemonSet para recolectar logs de todos los pods del clúster, enriquecerlos con metadatos de Kubernetes y enviarlos a Elasticsearch.

### Instrucciones

1. Crear el ConfigMap con la configuración de Fluentd:

```bash
cat > ~/k8s-labs/lab04/fluentd-configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: logging
data:
  fluent.conf: |
    # Entrada: logs de contenedores
    <source>
      @type tail
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type regexp
        expression /^(?<time>.+) (?<stream>stdout|stderr) [^ ]* (?<log>.*)$/
        time_format %Y-%m-%dT%H:%M:%S.%NZ
      </parse>
    </source>

    # Filtro: enriquecimiento con metadatos de Kubernetes
    <filter kubernetes.**>
      @type kubernetes_metadata
      @id filter_kube_metadata
      kubernetes_url "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
      verify_ssl false
      cache_size 1000
      cache_ttl 300
    </filter>

    # Filtro: parsear campo log como JSON si es posible
    <filter kubernetes.**>
      @type parser
      key_name log
      reserve_data true
      remove_key_name_field false
      <parse>
        @type json
        json_parser json
      </parse>
    </filter>

    # Filtro: extraer trace_id si existe en el log
    <filter kubernetes.**>
      @type record_transformer
      enable_ruby true
      <record>
        trace_id ${record.dig("trace_id") || record.dig("traceId") || "none"}
        namespace ${record.dig("kubernetes", "namespace_name") || "unknown"}
        pod_name ${record.dig("kubernetes", "pod_name") || "unknown"}
        container_name ${record.dig("kubernetes", "container_name") || "unknown"}
      </record>
    </filter>

    # Salida: Elasticsearch
    <match kubernetes.**>
      @type elasticsearch
      @id out_es
      host elasticsearch-master.logging.svc.cluster.local
      port 9200
      user elastic
      password ElasticK8s2024!
      scheme http
      logstash_format true
      logstash_prefix kubernetes
      logstash_dateformat %Y.%m.%d
      include_tag_key true
      tag_key @tag
      flush_interval 5s
      retry_max_interval 30
      retry_forever true
      suppress_type_name true
      <buffer>
        @type file
        path /var/log/fluentd-buffers/kubernetes.system.buffer
        flush_mode interval
        flush_interval 5s
        chunk_limit_size 2M
        total_limit_size 500M
        overflow_action block
      </buffer>
    </match>
EOF
```

2. Crear el ServiceAccount y RBAC para Fluentd:

```bash
cat > ~/k8s-labs/lab04/fluentd-rbac.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentd
subjects:
  - kind: ServiceAccount
    name: fluentd
    namespace: logging
EOF
```

3. Crear el DaemonSet de Fluentd:

```bash
cat > ~/k8s-labs/lab04/fluentd-daemonset.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: logging
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
      serviceAccountName: fluentd
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      containers:
        - name: fluentd
          image: fluent/fluentd-kubernetes-daemonset:v1.17.0-debian-elasticsearch8-1.0
          env:
            - name: FLUENT_ELASTICSEARCH_HOST
              value: "elasticsearch-master.logging.svc.cluster.local"
            - name: FLUENT_ELASTICSEARCH_PORT
              value: "9200"
            - name: FLUENT_ELASTICSEARCH_SCHEME
              value: "http"
            - name: FLUENT_ELASTICSEARCH_USER
              value: "elastic"
            - name: FLUENT_ELASTICSEARCH_PASSWORD
              value: "ElasticK8s2024!"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: varlog
              mountPath: /var/log
            - name: dockercontainerlogdirectory
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: fluentd-config
              mountPath: /fluentd/etc/fluent.conf
              subPath: fluent.conf
            - name: buffer
              mountPath: /var/log/fluentd-buffers
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: dockercontainerlogdirectory
          hostPath:
            path: /var/lib/docker/containers
        - name: fluentd-config
          configMap:
            name: fluentd-config
        - name: buffer
          emptyDir: {}
EOF
```

4. Aplicar todos los manifiestos:

```bash
kubectl apply -f ~/k8s-labs/lab04/fluentd-configmap.yaml
kubectl apply -f ~/k8s-labs/lab04/fluentd-rbac.yaml
kubectl apply -f ~/k8s-labs/lab04/fluentd-daemonset.yaml
```

5. Esperar a que todos los pods de Fluentd estén listos:

```bash
kubectl rollout status daemonset/fluentd -n logging --timeout=120s
```

### Salida Esperada

```
daemon set "fluentd" successfully rolled out
```

### Verificación

```bash
# Verificar que hay un pod Fluentd en cada nodo
kubectl get pods -n logging -l app=fluentd -o wide

# Verificar que los índices se están creando en Elasticsearch
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! http://localhost:9200/_cat/indices?v | grep kubernetes
```

Debe mostrar al menos un índice con patrón `kubernetes-YYYY.MM.DD` con documentos.

---

## Paso 4: Desplegar Jaeger Operator y Jaeger

### Objetivo

Instalar el Jaeger Operator y crear una instancia Jaeger en modo producción con Elasticsearch como backend de almacenamiento de trazas.

### Instrucciones

1. Instalar el Jaeger Operator mediante Helm:

```bash
helm install jaeger-operator jaegertracing/jaeger-operator \
  --namespace logging \
  --set rbac.clusterRole=true \
  --set image.tag=1.58.0 \
  --wait --timeout 3m
```

2. Esperar a que el operator esté listo:

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=jaeger-operator \
  --namespace logging --timeout=120s
```

3. Crear el recurso Jaeger CRD tipo producción:

```bash
cat > ~/k8s-labs/lab04/jaeger-instance.yaml << 'EOF'
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: jaeger-production
  namespace: logging
spec:
  strategy: production
  
  collector:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    options:
      collector:
        zipkin:
          host-port: ":9411"
  
  query:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi

  storage:
    type: elasticsearch
    options:
      es:
        server-urls: http://elasticsearch-master.logging.svc.cluster.local:9200
        username: elastic
        password: ElasticK8s2024!
        index-prefix: jaeger
        tls:
          enabled: false
    esIndexCleaner:
      enabled: true
      numberOfDays: 7
      schedule: "55 23 * * *"
EOF
```

4. Aplicar el recurso Jaeger:

```bash
kubectl apply -f ~/k8s-labs/lab04/jaeger-instance.yaml
```

5. Esperar a que los componentes de Jaeger estén listos:

```bash
# Esperar al collector
kubectl wait --for=condition=ready pod -l app=jaeger \
  -l app.kubernetes.io/component=collector \
  --namespace logging --timeout=180s

# Esperar al query
kubectl wait --for=condition=ready pod -l app=jaeger \
  -l app.kubernetes.io/component=query \
  --namespace logging --timeout=180s
```

### Salida Esperada

```
pod/jaeger-production-collector-<hash> condition met
pod/jaeger-production-query-<hash> condition met
```

### Verificación

```bash
# Listar todos los componentes de Jaeger
kubectl get pods -n logging -l app=jaeger

# Verificar que el servicio de query está disponible
kubectl get svc -n logging | grep jaeger-production-query
```

Debe mostrar pods de `collector` y `query` en estado Running, y un servicio en el puerto 16686.

---

## Paso 5: Desplegar OpenTelemetry Collector como Sidecar

### Objetivo

Instrumentar la aplicación `webapp` con un OpenTelemetry Collector sidecar que capture trazas y las envíe a Jaeger, implementando W3C TraceContext para propagación de trace-id.

### Instrucciones

1. Crear el ConfigMap del OpenTelemetry Collector:

```bash
cat > ~/k8s-labs/lab04/otel-collector-config.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: webapp
data:
  otel-collector-config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"

    processors:
      batch:
        timeout: 5s
        send_batch_size: 512
      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64
      resource:
        attributes:
          - key: service.namespace
            value: webapp
            action: upsert

    exporters:
      otlp/jaeger:
        endpoint: "jaeger-production-collector.logging.svc.cluster.local:4317"
        tls:
          insecure: true
      logging:
        loglevel: info

    extensions:
      health_check:
        endpoint: "0.0.0.0:13133"

    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [otlp/jaeger, logging]
EOF
```

2. Crear la aplicación `webapp` instrumentada con OpenTelemetry y sidecar:

```bash
cat > ~/k8s-labs/lab04/webapp-instrumented.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-traced
  namespace: webapp
  labels:
    app: webapp-traced
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp-traced
  template:
    metadata:
      labels:
        app: webapp-traced
    spec:
      containers:
        # Aplicación principal con instrumentación OTEL
        - name: webapp
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://localhost:4318"
            - name: OTEL_SERVICE_NAME
              value: "webapp"
            - name: OTEL_PROPAGATORS
              value: "tracecontext,baggage"
            - name: OTEL_TRACES_SAMPLER
              value: "always_on"
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

        # OpenTelemetry Collector sidecar
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.103.0
          args: ["--config=/etc/otel/otel-collector-config.yaml"]
          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
            - containerPort: 13133
              name: health
          volumeMounts:
            - name: otel-config
              mountPath: /etc/otel
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 13133
            initialDelaySeconds: 5

      volumes:
        - name: otel-config
          configMap:
            name: otel-collector-config
        - name: nginx-config
          configMap:
            name: webapp-nginx-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: webapp-nginx-config
  namespace: webapp
data:
  default.conf: |
    log_format json_combined escape=json
      '{'
        '"time_local":"$time_local",'
        '"remote_addr":"$remote_addr",'
        '"request":"$request",'
        '"status": "$status",'
        '"body_bytes_sent":"$body_bytes_sent",'
        '"http_referer":"$http_referer",'
        '"http_user_agent":"$http_user_agent",'
        '"request_id":"$request_id",'
        '"trace_id":"$http_traceparent"'
      '}';

    server {
      listen 80;
      server_name _;
      
      access_log /var/log/nginx/access.log json_combined;
      error_log /var/log/nginx/error.log warn;

      location / {
        root /usr/share/nginx/html;
        index index.html;
        
        # Propagar W3C TraceContext headers
        add_header X-Trace-Id $http_traceparent always;
      }

      location /health {
        access_log off;
        return 200 "OK\n";
      }

      location /api/trace-test {
        default_type application/json;
        return 200 '{"message":"trace-test","trace_id":"$http_traceparent","timestamp":"$time_iso8601"}';
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: webapp-traced
  namespace: webapp
spec:
  selector:
    app: webapp-traced
  ports:
    - port: 80
      targetPort: 80
      name: http
  type: ClusterIP
EOF
```

3. Aplicar los manifiestos:

```bash
kubectl apply -f ~/k8s-labs/lab04/otel-collector-config.yaml
kubectl apply -f ~/k8s-labs/lab04/webapp-instrumented.yaml
```

4. Esperar a que los pods estén listos:

```bash
kubectl wait --for=condition=ready pod -l app=webapp-traced \
  --namespace webapp --timeout=120s
```

### Salida Esperada

```
pod/webapp-traced-<hash1> condition met
pod/webapp-traced-<hash2> condition met
```

### Verificación

```bash
# Verificar que ambos contenedores están corriendo en cada pod
kubectl get pods -n webapp -l app=webapp-traced -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.containerStatuses[*]}{.name}={.ready}{" "}{end}{"\n"}{end}'

# Verificar que el otel-collector está healthy
kubectl exec -n webapp $(kubectl get pod -n webapp -l app=webapp-traced -o jsonpath='{.items[0].metadata.name}') \
  -c otel-collector -- wget -qO- http://localhost:13133/
```

---

## Paso 6: Generar Tráfico y Verificar Correlación

### Objetivo

Generar tráfico con headers W3C TraceContext hacia la aplicación instrumentada y verificar que los logs en Elasticsearch contienen trace-ids correlacionables con las trazas en Jaeger.

### Instrucciones

1. Generar tráfico con trace-id propagado:

```bash
# Crear un pod de prueba para generar tráfico
cat > ~/k8s-labs/lab04/traffic-generator.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: traffic-generator
  namespace: webapp
spec:
  template:
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.5.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              for i in $(seq 1 50); do
                TRACE_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)
                SPAN_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 16 | head -n 1)
                TRACEPARENT="00-${TRACE_ID}-${SPAN_ID}-01"
                curl -s -H "traceparent: ${TRACEPARENT}" \
                  http://webapp-traced.webapp.svc.cluster.local/api/trace-test
                curl -s -H "traceparent: ${TRACEPARENT}" \
                  http://webapp-traced.webapp.svc.cluster.local/
                sleep 0.5
              done
              echo "Traffic generation complete"
      restartPolicy: Never
  backoffLimit: 1
EOF

kubectl apply -f ~/k8s-labs/lab04/traffic-generator.yaml
```

2. Esperar a que el job complete:

```bash
kubectl wait --for=condition=complete job/traffic-generator \
  --namespace webapp --timeout=120s
```

3. Verificar que los logs con trace-id están en Elasticsearch:

```bash
# Esperar unos segundos para que Fluentd envíe los logs
sleep 15

# Buscar logs que contengan trace_id
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/kubernetes-*/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 5,
    "query": {
      "bool": {
        "must": [
          {"match": {"kubernetes.namespace_name": "webapp"}},
          {"exists": {"field": "trace_id"}}
        ],
        "must_not": [
          {"match": {"trace_id": "none"}}
        ]
      }
    },
    "sort": [{"@timestamp": "desc"}]
  }'
```

4. Verificar trazas en Jaeger:

```bash
# Consultar servicios registrados en Jaeger
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/jaeger-span-*/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 3,
    "query": {"match_all": {}},
    "sort": [{"startTime": "desc"}]
  }'
```

### Salida Esperada

Los logs deben contener campos `trace_id` con valores hexadecimales de 32 caracteres. Las trazas en los índices `jaeger-span-*` deben existir si el collector está enviando correctamente.

### Verificación

```bash
# Contar documentos con trace_id válido
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/kubernetes-*/_count' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "bool": {
        "must": [
          {"match": {"kubernetes.namespace_name": "webapp"}},
          {"wildcard": {"trace_id": "?*"}}
        ],
        "must_not": [{"term": {"trace_id": "none"}}]
      }
    }
  }'
```

Debe mostrar un `count` mayor que 0.

---

## Paso 7: Configurar Index Pattern en Kibana y Dashboard

### Objetivo

Crear index patterns en Kibana y un saved search para visualizar logs con trace-id, facilitando la correlación con Jaeger UI.

### Instrucciones

1. Crear el index pattern para logs de Kubernetes:

```bash
# Crear index pattern via API de Kibana
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X POST \
  'http://kibana-kibana.logging.svc.cluster.local:5601/api/saved_objects/index-pattern/kubernetes-logs' \
  -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' \
  -u elastic:ElasticK8s2024! \
  -d '{
    "attributes": {
      "title": "kubernetes-*",
      "timeFieldName": "@timestamp",
      "fields": "[]"
    }
  }'
```

2. Crear el index pattern para trazas de Jaeger:

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X POST \
  'http://kibana-kibana.logging.svc.cluster.local:5601/api/saved_objects/index-pattern/jaeger-spans' \
  -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' \
  -u elastic:ElasticK8s2024! \
  -d '{
    "attributes": {
      "title": "jaeger-span-*",
      "timeFieldName": "startTimeMillis",
      "fields": "[]"
    }
  }'
```

3. Crear un saved search para logs con trace-id de la webapp:

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X POST \
  'http://kibana-kibana.logging.svc.cluster.local:5601/api/saved_objects/search/webapp-traces' \
  -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' \
  -u elastic:ElasticK8s2024! \
  -d '{
    "attributes": {
      "title": "Webapp Logs with Trace ID",
      "description": "Logs from webapp namespace with trace correlation",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"kubernetes-logs\",\"query\":{\"query\":\"kubernetes.namespace_name: webapp AND NOT trace_id: none\",\"language\":\"kuery\"},\"filter\":[]}"
      }
    }
  }'
```

4. Verificar acceso a Jaeger UI (en otra terminal):

```bash
# Port-forward para acceder a Jaeger UI
kubectl port-forward -n logging svc/jaeger-production-query 16686:16686 &
echo "Jaeger UI disponible en: http://localhost:16686"

# Port-forward para acceder a Kibana
kubectl port-forward -n logging svc/kibana-kibana 5601:5601 &
echo "Kibana disponible en: http://localhost:5601 (elastic/ElasticK8s2024!)"
```

### Salida Esperada

```
Jaeger UI disponible en: http://localhost:16686
Kibana disponible en: http://localhost:5601 (elastic/ElasticK8s2024!)
```

### Verificación

```bash
# Verificar que los index patterns existen
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://kibana-kibana.logging.svc.cluster.local:5601/api/saved_objects/_find?type=index-pattern' \
  -H 'kbn-xsrf: true' | python3 -c "
import sys, json
data = json.load(sys.stdin)
for obj in data.get('saved_objects', []):
    print(f\"  - {obj['attributes']['title']}\")"
```

Debe listar `kubernetes-*` y `jaeger-span-*`.

---

## Paso 8: Configurar Index Lifecycle Management (ILM)

### Objetivo

Implementar una política ILM en Elasticsearch para gestionar automáticamente la retención y eliminación de índices de logs y trazas.

### Instrucciones

1. Crear la política ILM para logs:

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X PUT \
  'http://localhost:9200/_ilm/policy/kubernetes-logs-policy' \
  -H 'Content-Type: application/json' \
  -u elastic:ElasticK8s2024! \
  -d '{
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": {
              "max_age": "1d",
              "max_primary_shard_size": "5gb"
            }
          }
        },
        "warm": {
          "min_age": "2d",
          "actions": {
            "shrink": {
              "number_of_shards": 1
            },
            "forcemerge": {
              "max_num_segments": 1
            }
          }
        },
        "delete": {
          "min_age": "7d",
          "actions": {
            "delete": {}
          }
        }
      }
    }
  }'
```

2. Crear un index template que aplique la política:

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X PUT \
  'http://localhost:9200/_index_template/kubernetes-logs-template' \
  -H 'Content-Type: application/json' \
  -u elastic:ElasticK8s2024! \
  -d '{
    "index_patterns": ["kubernetes-*"],
    "template": {
      "settings": {
        "index.lifecycle.name": "kubernetes-logs-policy",
        "number_of_shards": 1,
        "number_of_replicas": 0
      }
    },
    "priority": 100
  }'
```

3. Verificar la política:

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/_ilm/policy/kubernetes-logs-policy?pretty'
```

### Salida Esperada

```json
{
  "kubernetes-logs-policy": {
    "version": 1,
    "policy": {
      "phases": {
        "hot": { ... },
        "warm": { ... },
        "delete": { "min_age": "7d", ... }
      }
    }
  }
}
```

### Verificación

```bash
# Verificar que el template está aplicado
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/_index_template/kubernetes-logs-template?pretty' | \
  grep -A2 "lifecycle"
```

Debe mostrar `"index.lifecycle.name": "kubernetes-logs-policy"`.

---

## Validación y Testing

Ejecutar la siguiente secuencia de validación completa:

```bash
echo "=== VALIDACIÓN COMPLETA DEL LAB 04 ==="

echo ""
echo "1. Verificando Elasticsearch..."
ES_STATUS=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! http://localhost:9200/_cluster/health | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
echo "   Estado del clúster: $ES_STATUS"
[ "$ES_STATUS" = "green" ] || [ "$ES_STATUS" = "yellow" ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "2. Verificando Kibana..."
KIBANA_STATUS=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! http://kibana-kibana:5601/api/status | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status']['overall']['level'])" 2>/dev/null)
echo "   Estado de Kibana: $KIBANA_STATUS"
[ "$KIBANA_STATUS" = "available" ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "3. Verificando Fluentd DaemonSet..."
FLUENTD_DESIRED=$(kubectl get daemonset fluentd -n logging -o jsonpath='{.status.desiredNumberScheduled}')
FLUENTD_READY=$(kubectl get daemonset fluentd -n logging -o jsonpath='{.status.numberReady}')
echo "   Pods deseados/listos: $FLUENTD_DESIRED/$FLUENTD_READY"
[ "$FLUENTD_DESIRED" = "$FLUENTD_READY" ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "4. Verificando Jaeger componentes..."
JAEGER_COLLECTOR=$(kubectl get pods -n logging -l app.kubernetes.io/component=collector -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
JAEGER_QUERY=$(kubectl get pods -n logging -l app.kubernetes.io/component=query -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
echo "   Collector: $JAEGER_COLLECTOR | Query: $JAEGER_QUERY"
[ "$JAEGER_COLLECTOR" = "Running" ] && [ "$JAEGER_QUERY" = "Running" ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "5. Verificando webapp-traced con sidecar..."
WEBAPP_CONTAINERS=$(kubectl get pods -n webapp -l app=webapp-traced -o jsonpath='{.items[0].spec.containers[*].name}')
echo "   Contenedores: $WEBAPP_CONTAINERS"
echo "$WEBAPP_CONTAINERS" | grep -q "otel-collector" && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "6. Verificando índices en Elasticsearch..."
INDEX_COUNT=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! 'http://localhost:9200/_cat/indices?h=index' | \
  grep -c "kubernetes-")
echo "   Índices kubernetes-*: $INDEX_COUNT"
[ "$INDEX_COUNT" -ge 1 ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "7. Verificando logs con trace_id..."
TRACE_LOGS=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/kubernetes-*/_count' \
  -H 'Content-Type: application/json' \
  -d '{"query":{"bool":{"must":[{"match":{"kubernetes.namespace_name":"webapp"}}]}}}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))")
echo "   Logs de webapp en ES: $TRACE_LOGS"
[ "$TRACE_LOGS" -ge 1 ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "8. Verificando ILM Policy..."
ILM_EXISTS=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! \
  'http://localhost:9200/_ilm/policy/kubernetes-logs-policy' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('exists' if 'kubernetes-logs-policy' in d else 'missing')")
echo "   Política ILM: $ILM_EXISTS"
[ "$ILM_EXISTS" = "exists" ] && echo "   ✓ PASS" || echo "   ✗ FAIL"

echo ""
echo "=== VALIDACIÓN COMPLETADA ==="
```

---

## Troubleshooting

### Problema 1: Elasticsearch no arranca — CrashLoopBackOff por vm.max_map_count

**Síntomas:**
```
kubectl get pods -n logging
NAME                      READY   STATUS             RESTARTS   AGE
elasticsearch-master-0    0/1     CrashLoopBackOff   3          2m
```

Logs muestran: `max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [262144]`

**Causa:** Los nodos kind no tienen configurado `vm.max_map_count=262144`. Este parámetro del kernel es requerido por Elasticsearch para mapear ficheros de índices en memoria.

**Solución:**

```bash
# Configurar en todos los nodos kind
for node in $(kind get nodes --name lab-calico); do
  docker exec $node sysctl -w vm.max_map_count=262144
done

# Reiniciar el pod de Elasticsearch
kubectl delete pod elasticsearch-master-0 -n logging

# Esperar a que arranque correctamente
kubectl wait --for=condition=ready pod/elasticsearch-master-0 \
  --namespace logging --timeout=300s
```

---

### Problema 2: Fluentd no envía logs a Elasticsearch — Connection refused

**Síntomas:**

Los pods de Fluentd están Running pero no aparecen índices `kubernetes-*` en Elasticsearch. Los logs de Fluentd muestran:

```
[warn]: #0 failed to flush the buffer. retry_times=5 ... Connection refused - connect(2) for "elasticsearch-master.logging.svc.cluster.local" port 9200
```

**Causa:** Fluentd se inició antes de que Elasticsearch estuviera completamente listo, y los reintentos se agotaron o el buffer se corrompió. También puede ocurrir si el Service de Elasticsearch no resuelve correctamente.

**Solución:**

```bash
# Verificar que Elasticsearch está accesible desde el namespace logging
kubectl run test-es --rm -it --restart=Never -n logging \
  --image=curlimages/curl:8.5.0 -- \
  curl -s -u elastic:ElasticK8s2024! http://elasticsearch-master:9200/_cluster/health

# Si Elasticsearch está healthy, reiniciar Fluentd para limpiar buffers
kubectl rollout restart daemonset/fluentd -n logging

# Esperar al rollout
kubectl rollout status daemonset/fluentd -n logging --timeout=120s

# Verificar que los índices empiezan a crearse (esperar ~30s)
sleep 30
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -u elastic:ElasticK8s2024! 'http://localhost:9200/_cat/indices?v' | grep kubernetes
```

---

## Limpieza

Si necesitas eliminar todos los recursos del lab (no recomendado si vas a continuar con Lab 05):

```bash
# Eliminar traffic generator
kubectl delete job traffic-generator -n webapp --ignore-not-found

# Eliminar webapp instrumentada
kubectl delete -f ~/k8s-labs/lab04/webapp-instrumented.yaml --ignore-not-found
kubectl delete -f ~/k8s-labs/lab04/otel-collector-config.yaml --ignore-not-found

# Eliminar Jaeger
kubectl delete -f ~/k8s-labs/lab04/jaeger-instance.yaml --ignore-not-found
helm uninstall jaeger-operator -n logging 2>/dev/null

# Eliminar Fluentd
kubectl delete -f ~/k8s-labs/lab04/fluentd-daemonset.yaml --ignore-not-found
kubectl delete -f ~/k8s-labs/lab04/fluentd-rbac.yaml --ignore-not-found
kubectl delete -f ~/k8s-labs/lab04/fluentd-configmap.yaml --ignore-not-found

# Eliminar Kibana y Elasticsearch
helm uninstall kibana -n logging 2>/dev/null
helm uninstall elasticsearch -n logging 2>/dev/null

# Eliminar PVCs
kubectl delete pvc -n logging --all

# Eliminar namespace (solo si no se necesita para Lab 05)
# kubectl delete namespace logging

# Detener port-forwards
pkill -f "port-forward.*16686" 2>/dev/null
pkill -f "port-forward.*5601" 2>/dev/null
```

> **Nota:** Elasticsearch y Kibana deben permanecer activos si vas a realizar el Lab 05. No ejecutes la limpieza completa en ese caso.

---

## Resumen

En este laboratorio se ha construido una infraestructura completa de observabilidad para logging y trazabilidad distribuida:

| Componente | Función | Estado |
|------------|---------|--------|
| Elasticsearch 8.14.1 | Almacenamiento de logs y trazas | Single-node, 10Gi PVC |
| Kibana 8.14.1 | Visualización y búsqueda de logs | Index patterns configurados |
| Fluentd 1.17.0 | Recolección de logs como DaemonSet | Enriquecimiento con metadatos K8s |
| Jaeger 1.58.0 | Trazabilidad distribuida | Modo producción con ES backend |
| OTel Collector 0.103.0 | Captura de trazas como sidecar | Exporta a Jaeger vía OTLP |
| ILM Policy | Gestión del ciclo de vida de índices | Retención 7 días |

### Conceptos Clave Aplicados

- **Modelo de logging a nivel de nodo**: Fluentd como DaemonSet lee logs de `/var/log/containers/` en cada nodo
- **Enriquecimiento de metadatos**: Filtro `kubernetes_metadata` añade namespace, pod y container a cada log
- **Trazabilidad distribuida**: W3C TraceContext propaga trace-id entre servicios
- **Correlación logs-trazas**: El campo `trace_id` en los logs permite buscar en Kibana y correlacionar con spans en Jaeger
- **Index Lifecycle Management**: Automatiza la retención y eliminación de datos históricos

### Recursos Adicionales

- [Documentación Elasticsearch 8.x](https://www.elastic.co/guide/en/elasticsearch/reference/8.14/index.html)
- [Fluentd Kubernetes DaemonSet](https://docs.fluentd.org/container-deployment/kubernetes)
- [Jaeger Operator Documentation](https://www.jaegertracing.io/docs/1.58/operator/)
- [OpenTelemetry Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [W3C Trace Context Specification](https://www.w3.org/TR/trace-context/)
