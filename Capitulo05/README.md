# Desplegar Prometheus, Configurar Alertas y Simular Incidentes

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Descripción General

En este laboratorio desplegarás el stack completo de monitorización kube-prometheus-stack sobre el clúster `lab-calico`, configurarás ServiceMonitors para scraping automático de la aplicación `webapp`, diseñarás PrometheusRules con alertas basadas en SLOs, configurarás Alertmanager con routing avanzado e inhibition rules, y simularás incidentes reales (OOMKill, CrashLoopBackOff, alta latencia) para validar el flujo completo de detección y alerting.

## Objetivos de Aprendizaje

- [ ] Desplegar kube-prometheus-stack 61.3.0 con persistencia configurada para Prometheus TSDB y Grafana
- [ ] Configurar ServiceMonitor y PodMonitor CRDs para scraping automático de métricas custom de `webapp`
- [ ] Diseñar PrometheusRules con alertas agrupadas por infraestructura, Kubernetes y aplicación basadas en SLOs
- [ ] Configurar Alertmanager con routing rules, inhibition rules y receivers webhook
- [ ] Simular incidentes y validar el flujo completo de detección, alerta y resolución

## Prerrequisitos

### Conocimientos Requeridos

- Familiaridad con Helm charts y valores de configuración
- Comprensión del modelo pull de Prometheus y tipos de métricas (Counter, Gauge, Histogram)
- Conocimiento básico de PromQL
- Experiencia con CRDs de Kubernetes

### Acceso y Recursos

- Lab 01 completado: clúster `lab-calico` operativo con contexto `kind-lab-calico`
- Lab 02 completado: aplicación `webapp` desplegada en namespace `webapp` con endpoint `/metrics`
- Helm repo `prometheus-community` añadido
- Mínimo 8 GB RAM disponible adicional
- StorageClass `standard` con provisioner funcional

## Entorno del Laboratorio

| Componente | Versión/Detalle |
|------------|----------------|
| Kubernetes | 1.30.2 (kind) |
| kube-prometheus-stack | 61.3.0 |
| Prometheus | 2.53.0 |
| Grafana | 11.1.0 |
| Alertmanager | 0.27.0 |
| Directorio de trabajo | `~/k8s-labs/lab05/` |
| Namespace | `monitoring` |

### Preparación Inicial

```bash
# Verificar contexto del clúster
kubectl config use-context kind-lab-calico

# Crear directorio de trabajo
mkdir -p ~/k8s-labs/lab05/{values,rules,monitors,alertmanager,incidents,dashboards}
cd ~/k8s-labs/lab05/

# Verificar que el clúster está operativo
kubectl get nodes
# Debe mostrar 1 control-plane + 2 workers en estado Ready

# Verificar que webapp está desplegada
kubectl get pods -n webapp
kubectl get svc -n webapp

# Añadir repo Helm si no existe
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

## Paso a Paso

### Paso 1: Desplegar el Webhook Receiver para Alertmanager

**Objetivo:** Crear un servicio webhook que recibirá las alertas críticas de Alertmanager, permitiendo validar el flujo completo de alerting.

**Instrucciones:**

1. Crear el manifiesto del webhook receiver:

```bash
cat > ~/k8s-labs/lab05/alertmanager/webhook-receiver.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager-webhook
  namespace: monitoring
  labels:
    app: alertmanager-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alertmanager-webhook
  template:
    metadata:
      labels:
        app: alertmanager-webhook
    spec:
      containers:
        - name: webhook
          image: python:3.11-slim
          ports:
            - containerPort: 5001
          command:
            - python3
            - -c
            - |
              from http.server import HTTPServer, BaseHTTPRequestHandler
              import json, datetime

              class WebhookHandler(BaseHTTPRequestHandler):
                  def do_POST(self):
                      content_length = int(self.headers['Content-Length'])
                      body = self.rfile.read(content_length)
                      alerts = json.loads(body)
                      timestamp = datetime.datetime.now().isoformat()
                      print(f"[{timestamp}] Received {len(alerts.get('alerts', []))} alert(s):")
                      for alert in alerts.get('alerts', []):
                          status = alert.get('status', 'unknown')
                          name = alert.get('labels', {}).get('alertname', 'unnamed')
                          severity = alert.get('labels', {}).get('severity', 'unknown')
                          print(f"  - [{status}] {name} (severity: {severity})")
                      self.send_response(200)
                      self.end_headers()
                      self.wfile.write(b'OK')

              print("Webhook receiver listening on port 5001...")
              HTTPServer(('', 5001), WebhookHandler).serve_forever()
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager-webhook
  namespace: monitoring
spec:
  selector:
    app: alertmanager-webhook
  ports:
    - port: 5001
      targetPort: 5001
      protocol: TCP
EOF
```

2. Aplicar el manifiesto:

```bash
kubectl apply -f ~/k8s-labs/lab05/alertmanager/webhook-receiver.yaml
```

3. Verificar que el webhook está operativo:

```bash
kubectl wait --for=condition=Ready pod -l app=alertmanager-webhook -n monitoring --timeout=120s
```

**Salida esperada:**

```
namespace/monitoring created
deployment.apps/alertmanager-webhook created
service/alertmanager-webhook created
pod/alertmanager-webhook-xxxxx condition met
```

**Verificación:**

```bash
kubectl get pods -n monitoring -l app=alertmanager-webhook
# STATUS debe ser Running
```

---

### Paso 2: Crear los Valores de Configuración para kube-prometheus-stack

**Objetivo:** Preparar el archivo de valores Helm con persistencia, configuración de Alertmanager, Grafana y ServiceMonitor selectors.

**Instrucciones:**

1. Crear el archivo de valores principal:

```bash
cat > ~/k8s-labs/lab05/values/kube-prometheus-stack-values.yaml << 'EOF'
# kube-prometheus-stack 61.3.0 - Valores personalizados
fullnameOverride: ""
namespaceOverride: "monitoring"

# --- Prometheus ---
prometheus:
  prometheusSpec:
    replicas: 1
    retention: 7d
    retentionSize: "18GB"
    scrapeInterval: 30s
    evaluationInterval: 30s
    # Seleccionar ServiceMonitors de todos los namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    # Seleccionar PodMonitors de todos los namespaces
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorSelector: {}
    podMonitorNamespaceSelector: {}
    # Seleccionar PrometheusRules de todos los namespaces
    ruleSelectorNilUsesHelmValues: false
    ruleSelector: {}
    ruleNamespaceSelector: {}
    # Persistencia TSDB
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: standard
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    resources:
      requests:
        memory: "1Gi"
        cpu: "500m"
      limits:
        memory: "2Gi"
        cpu: "1000m"

# --- Alertmanager ---
alertmanager:
  alertmanagerSpec:
    replicas: 1
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "200m"
  config:
    global:
      resolve_timeout: 5m
    inhibit_rules:
      # Suprimir alertas de pod cuando el nodo está down
      - source_matchers:
          - alertname = NodeDown
          - severity = critical
        target_matchers:
          - severity =~ "warning|info"
        equal:
          - node
      # Suprimir warnings cuando hay critical del mismo alertname
      - source_matchers:
          - severity = critical
        target_matchers:
          - severity = warning
        equal:
          - alertname
          - namespace
    route:
      group_by: ['namespace', 'alertname', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'null'
      routes:
        - receiver: 'critical-webhook'
          matchers:
            - severity = critical
          continue: false
          group_wait: 10s
          repeat_interval: 1h
        - receiver: 'warning-slack'
          matchers:
            - severity = warning
          continue: false
        - receiver: 'null'
          matchers:
            - alertname =~ "InfoInhibitedAlertCount|Watchdog"
    receivers:
      - name: 'null'
      - name: 'critical-webhook'
        webhook_configs:
          - url: 'http://alertmanager-webhook.monitoring.svc:5001'
            send_resolved: true
      - name: 'warning-slack'
        webhook_configs:
          - url: 'http://alertmanager-webhook.monitoring.svc:5001'
            send_resolved: true

# --- Grafana ---
grafana:
  enabled: true
  adminUser: admin
  adminPassword: "KubeGrafana2024!"
  persistence:
    enabled: true
    storageClassName: standard
    size: 5Gi
  resources:
    requests:
      memory: "256Mi"
      cpu: "200m"
    limits:
      memory: "512Mi"
      cpu: "400m"
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
    datasources:
      enabled: true
  additionalDataSources:
    - name: Elasticsearch
      type: elasticsearch
      url: http://elasticsearch-master.logging.svc:9200
      access: proxy
      basicAuth: true
      basicAuthUser: elastic
      secureJsonData:
        basicAuthPassword: "ElasticK8s2024!"
      jsonData:
        index: "filebeat-*"
        timeField: "@timestamp"
        esVersion: "8.0.0"

# --- Node Exporter ---
nodeExporter:
  enabled: true

# --- kube-state-metrics ---
kubeStateMetrics:
  enabled: true

# --- Prometheus Operator ---
prometheusOperator:
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"
EOF
```

**Salida esperada:** Archivo creado sin errores.

**Verificación:**

```bash
cat ~/k8s-labs/lab05/values/kube-prometheus-stack-values.yaml | head -5
# Debe mostrar el comentario inicial del archivo
```

---

### Paso 3: Instalar kube-prometheus-stack con Helm

**Objetivo:** Desplegar el stack completo de monitorización en el namespace `monitoring`.

**Instrucciones:**

1. Instalar el chart:

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 61.3.0 \
  -f ~/k8s-labs/lab05/values/kube-prometheus-stack-values.yaml \
  --timeout 10m \
  --wait
```

2. Verificar que todos los componentes están running:

```bash
kubectl get pods -n monitoring -o wide
```

3. Verificar los CRDs instalados:

```bash
kubectl get crd | grep monitoring.coreos.com
```

**Salida esperada:**

```
NAME                                                  CREATED AT
alertmanagerconfigs.monitoring.coreos.com             2024-xx-xx
alertmanagers.monitoring.coreos.com                   2024-xx-xx
podmonitors.monitoring.coreos.com                     2024-xx-xx
probes.monitoring.coreos.com                          2024-xx-xx
prometheusagents.monitoring.coreos.com                2024-xx-xx
prometheuses.monitoring.coreos.com                    2024-xx-xx
prometheusrules.monitoring.coreos.com                 2024-xx-xx
scrapeconfigs.monitoring.coreos.com                   2024-xx-xx
servicemonitors.monitoring.coreos.com                 2024-xx-xx
thanosrulers.monitoring.coreos.com                    2024-xx-xx
```

**Verificación:**

```bash
# Todos los pods deben estar Running/Ready
kubectl get pods -n monitoring --field-selector=status.phase!=Running 2>/dev/null | grep -v "No resources"

# Verificar Prometheus está respondiendo
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s http://localhost:9090/-/healthy
# Debe retornar: Prometheus Server is Healthy.
kill %1 2>/dev/null
```

---

### Paso 4: Desplegar la Aplicación webapp con Métricas Custom

**Objetivo:** Asegurar que la aplicación `webapp` expone métricas Prometheus en `/metrics` con counters, gauges e histogramas relevantes para SLOs.

**Instrucciones:**

1. Crear el deployment de webapp con métricas instrumentadas:

```bash
cat > ~/k8s-labs/lab05/incidents/webapp-metrics.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: webapp
  labels:
    app: webapp
    version: v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: webapp
          image: python:3.11-slim
          ports:
            - containerPort: 8080
              name: http
          command:
            - python3
            - -c
            - |
              from http.server import HTTPServer, BaseHTTPRequestHandler
              import random, time, threading, json

              # Métricas simples en memoria
              metrics = {
                  'http_requests_total': {},
                  'http_request_duration_seconds_bucket': {},
                  'http_request_duration_seconds_sum': 0,
                  'http_request_duration_seconds_count': 0,
                  'app_errors_total': {},
                  'app_memory_usage_bytes': 50 * 1024 * 1024,
                  'app_up': 1
              }

              # Buckets para histograma
              buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
              for b in buckets + [float('inf')]:
                  metrics['http_request_duration_seconds_bucket'][str(b)] = 0

              def simulate_traffic():
                  while True:
                      method = random.choice(['GET', 'POST', 'GET', 'GET'])
                      status = random.choices(['200', '201', '500', '503'], weights=[85, 8, 4, 3])[0]
                      key = f'{method}_{status}'
                      metrics['http_requests_total'][key] = metrics['http_requests_total'].get(key, 0) + 1

                      if status in ['500', '503']:
                          err_key = f'{status}'
                          metrics['app_errors_total'][err_key] = metrics['app_errors_total'].get(err_key, 0) + 1

                      # Simular latencia
                      latency = random.expovariate(10)  # media ~100ms
                      metrics['http_request_duration_seconds_sum'] += latency
                      metrics['http_request_duration_seconds_count'] += 1
                      for b in buckets + [float('inf')]:
                          if latency <= b:
                              metrics['http_request_duration_seconds_bucket'][str(b)] += 1

                      time.sleep(random.uniform(0.1, 0.5))

              threading.Thread(target=simulate_traffic, daemon=True).start()

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      if self.path == '/metrics':
                          lines = []
                          lines.append('# HELP http_requests_total Total HTTP requests')
                          lines.append('# TYPE http_requests_total counter')
                          for key, val in metrics['http_requests_total'].items():
                              method, status = key.split('_')
                              lines.append(f'http_requests_total{{method="{method}",status="{status}",app="webapp"}} {val}')

                          lines.append('# HELP http_request_duration_seconds Request duration histogram')
                          lines.append('# TYPE http_request_duration_seconds histogram')
                          for b, val in metrics['http_request_duration_seconds_bucket'].items():
                              le = '+Inf' if b == 'inf' else b
                              lines.append(f'http_request_duration_seconds_bucket{{app="webapp",le="{le}"}} {val}')
                          lines.append(f'http_request_duration_seconds_sum{{app="webapp"}} {metrics["http_request_duration_seconds_sum"]:.4f}')
                          lines.append(f'http_request_duration_seconds_count{{app="webapp"}} {metrics["http_request_duration_seconds_count"]}')

                          lines.append('# HELP app_errors_total Total application errors')
                          lines.append('# TYPE app_errors_total counter')
                          for key, val in metrics['app_errors_total'].items():
                              lines.append(f'app_errors_total{{status="{key}",app="webapp"}} {val}')

                          lines.append('# HELP app_memory_usage_bytes Memory usage in bytes')
                          lines.append('# TYPE app_memory_usage_bytes gauge')
                          lines.append(f'app_memory_usage_bytes{{app="webapp"}} {metrics["app_memory_usage_bytes"]}')

                          lines.append('# HELP app_up Application health status')
                          lines.append('# TYPE app_up gauge')
                          lines.append(f'app_up{{app="webapp"}} {metrics["app_up"]}')

                          body = '\n'.join(lines) + '\n'
                          self.send_response(200)
                          self.send_header('Content-Type', 'text/plain; charset=utf-8')
                          self.end_headers()
                          self.wfile.write(body.encode())
                      elif self.path == '/health':
                          self.send_response(200)
                          self.end_headers()
                          self.wfile.write(b'OK')
                      else:
                          self.send_response(200)
                          self.end_headers()
                          self.wfile.write(b'Hello from webapp!')

                  def log_message(self, format, *args):
                      pass  # Suprimir logs de acceso

              print("Webapp listening on port 8080...")
              HTTPServer(('', 8080), Handler).serve_forever()
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: webapp
  labels:
    app: webapp
spec:
  selector:
    app: webapp
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 8080
      targetPort: 8080
EOF
```

2. Aplicar (crear namespace si no existe):

```bash
kubectl create namespace webapp --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/k8s-labs/lab05/incidents/webapp-metrics.yaml
kubectl wait --for=condition=Ready pod -l app=webapp -n webapp --timeout=120s
```

3. Verificar que las métricas se exponen correctamente:

```bash
kubectl port-forward svc/webapp -n webapp 8080:8080 &
sleep 2
curl -s http://localhost:8080/metrics | head -20
kill %1 2>/dev/null
```

**Salida esperada:**

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200",app="webapp"} 42
...
```

**Verificación:**

```bash
curl -s http://localhost:8080/metrics | grep -c "^http_requests_total"
# Debe retornar al menos 1
```

---

### Paso 5: Configurar ServiceMonitor para webapp

**Objetivo:** Crear un ServiceMonitor CRD que instruya al operador Prometheus para hacer scraping automático de las métricas de `webapp`.

**Instrucciones:**

1. Crear el ServiceMonitor:

```bash
cat > ~/k8s-labs/lab05/monitors/webapp-servicemonitor.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: webapp-monitor
  namespace: webapp
  labels:
    app: webapp
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: webapp
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
      scrapeTimeout: 10s
  namespaceSelector:
    matchNames:
      - webapp
EOF
```

2. Crear un ServiceMonitor adicional para NGINX Ingress Controller:

```bash
cat > ~/k8s-labs/lab05/monitors/ingress-servicemonitor.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ingress-nginx-monitor
  namespace: ingress-nginx
  labels:
    app: ingress-nginx
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ingress-nginx
      app.kubernetes.io/component: controller
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
  namespaceSelector:
    matchNames:
      - ingress-nginx
EOF
```

3. Aplicar los ServiceMonitors:

```bash
kubectl apply -f ~/k8s-labs/lab05/monitors/webapp-servicemonitor.yaml
kubectl apply -f ~/k8s-labs/lab05/monitors/ingress-servicemonitor.yaml
```

4. Verificar que Prometheus descubrió los targets:

```bash
# Esperar 30 segundos para que el operador reconcilie
sleep 30

kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
# Consultar targets activos
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -A2 "webapp"
kill %1 2>/dev/null
```

**Salida esperada:**

```
servicemonitor.monitoring.coreos.com/webapp-monitor created
servicemonitor.monitoring.coreos.com/ingress-nginx-monitor created
```

**Verificación:**

```bash
kubectl get servicemonitors -A
# Debe listar webapp-monitor en namespace webapp
```

---

### Paso 6: Crear PrometheusRules para Alertas SLO

**Objetivo:** Definir reglas de alerta agrupadas por infraestructura, Kubernetes y aplicación, basadas en SLOs de disponibilidad >99.5%, latencia p99 <500ms y error rate <1%.

**Instrucciones:**

1. Crear reglas de infraestructura:

```bash
cat > ~/k8s-labs/lab05/rules/infrastructure-rules.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: infrastructure-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    app: kube-prometheus-stack
spec:
  groups:
    - name: node.rules
      rules:
        - alert: NodeDown
          expr: up{job="node-exporter"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Nodo {{ $labels.instance }} está caído"
            description: "El nodo {{ $labels.instance }} no responde al scraping durante más de 2 minutos."
            runbook_url: "https://runbooks.internal/node-down"

        - alert: NodeMemoryPressure
          expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.90
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Nodo {{ $labels.instance }} con presión de memoria"
            description: "El nodo {{ $labels.instance }} tiene más del 90% de memoria utilizada durante 5 minutos. Uso actual: {{ $value | humanizePercentage }}"

        - alert: NodeDiskPressure
          expr: (1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Nodo {{ $labels.instance }} con presión de disco"
            description: "El disco del nodo {{ $labels.instance }} está al {{ $value | humanizePercentage }} de capacidad."
EOF
```

2. Crear reglas de Kubernetes:

```bash
cat > ~/k8s-labs/lab05/rules/kubernetes-rules.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubernetes-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    app: kube-prometheus-stack
spec:
  groups:
    - name: kubernetes.pods
      rules:
        - alert: PodCrashLooping
          expr: increase(kube_pod_container_status_restarts_total[15m]) > 3
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} en CrashLoopBackOff"
            description: "El contenedor {{ $labels.container }} del pod {{ $labels.pod }} se ha reiniciado {{ $value }} veces en los últimos 15 minutos."

        - alert: PodOOMKilled
          expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} terminado por OOMKill"
            description: "El contenedor {{ $labels.container }} fue terminado por exceso de memoria."

    - name: kubernetes.deployments
      rules:
        - alert: DeploymentNotAvailable
          expr: kube_deployment_status_available_replicas / kube_deployment_spec_replicas < 0.5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} no disponible"
            description: "Menos del 50% de las réplicas del deployment {{ $labels.deployment }} están disponibles."

        - alert: DeploymentReplicasMismatch
          expr: kube_deployment_status_ready_replicas != kube_deployment_spec_replicas
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} con réplicas desincronizadas"
            description: "El deployment {{ $labels.deployment }} tiene {{ $value }} réplicas listas pero se esperan {{ $labels.spec_replicas }}."
EOF
```

3. Crear reglas de aplicación (SLOs):

```bash
cat > ~/k8s-labs/lab05/rules/application-rules.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: webapp-slo-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    app: kube-prometheus-stack
spec:
  groups:
    - name: webapp.slo
      rules:
        # SLO: Error rate < 1%
        - alert: WebappHighErrorRate
          expr: |
            (
              sum(rate(http_requests_total{app="webapp",status=~"5.."}[5m]))
              /
              sum(rate(http_requests_total{app="webapp"}[5m]))
            ) > 0.01
          for: 2m
          labels:
            severity: critical
            slo: error-rate
          annotations:
            summary: "Webapp: tasa de errores supera el SLO del 1%"
            description: "La tasa de errores HTTP 5xx de webapp es {{ $value | humanizePercentage }}, superando el umbral del 1%."

        # SLO: Latencia p99 < 500ms
        - alert: WebappHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{app="webapp"}[5m])) by (le)
            ) > 0.5
          for: 2m
          labels:
            severity: critical
            slo: latency
          annotations:
            summary: "Webapp: latencia p99 supera el SLO de 500ms"
            description: "La latencia p99 de webapp es {{ $value }}s, superando el umbral de 0.5s."

        # SLO: Disponibilidad > 99.5%
        - alert: WebappLowAvailability
          expr: |
            (
              sum(rate(http_requests_total{app="webapp",status=~"2..|3.."}[5m]))
              /
              sum(rate(http_requests_total{app="webapp"}[5m]))
            ) < 0.995
          for: 5m
          labels:
            severity: critical
            slo: availability
          annotations:
            summary: "Webapp: disponibilidad por debajo del SLO de 99.5%"
            description: "La disponibilidad de webapp es {{ $value | humanizePercentage }}, por debajo del umbral de 99.5%."

        # Alerta temprana (warning) - Error budget burning
        - alert: WebappErrorBudgetBurning
          expr: |
            (
              sum(rate(http_requests_total{app="webapp",status=~"5.."}[30m]))
              /
              sum(rate(http_requests_total{app="webapp"}[30m]))
            ) > 0.005
          for: 5m
          labels:
            severity: warning
            slo: error-budget
          annotations:
            summary: "Webapp: consumo acelerado del error budget"
            description: "La tasa de errores en ventana de 30m es {{ $value | humanizePercentage }}, consumiendo error budget rápidamente."
EOF
```

4. Aplicar todas las reglas:

```bash
kubectl apply -f ~/k8s-labs/lab05/rules/infrastructure-rules.yaml
kubectl apply -f ~/k8s-labs/lab05/rules/kubernetes-rules.yaml
kubectl apply -f ~/k8s-labs/lab05/rules/application-rules.yaml
```

**Salida esperada:**

```
prometheusrule.monitoring.coreos.com/infrastructure-alerts created
prometheusrule.monitoring.coreos.com/kubernetes-alerts created
prometheusrule.monitoring.coreos.com/webapp-slo-alerts created
```

**Verificación:**

```bash
kubectl get prometheusrules -n monitoring
# Debe listar las 3 reglas creadas

# Verificar que Prometheus cargó las reglas
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s http://localhost:9090/api/v1/rules | python3 -c "
import json, sys
data = json.load(sys.stdin)
groups = data['data']['groups']
custom_groups = [g['name'] for g in groups if 'webapp' in g['name'] or 'node.rules' in g['name'] or 'kubernetes' in g['name']]
print(f'Grupos de reglas custom encontrados: {len(custom_groups)}')
for g in custom_groups:
    print(f'  - {g}')
"
kill %1 2>/dev/null
```

---

### Paso 7: Crear Dashboards de Grafana

**Objetivo:** Provisionar dashboards de Grafana como ConfigMaps para visualizar SLOs de webapp, estado del clúster y overview de Alertmanager.

**Instrucciones:**

1. Crear el dashboard de SLOs de Webapp:

```bash
cat > ~/k8s-labs/lab05/dashboards/webapp-slo-dashboard.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: webapp-slo-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  webapp-slos.json: |
    {
      "annotations": {"list": []},
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "id": null,
      "links": [],
      "panels": [
        {
          "title": "Error Rate (SLO < 1%)",
          "type": "gauge",
          "gridPos": {"h": 8, "w": 8, "x": 0, "y": 0},
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{app=\"webapp\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{app=\"webapp\"}[5m])) * 100",
              "legendFormat": "Error Rate %"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  {"color": "green", "value": null},
                  {"color": "yellow", "value": 0.5},
                  {"color": "red", "value": 1}
                ]
              },
              "unit": "percent",
              "max": 5
            }
          }
        },
        {
          "title": "Latencia P99 (SLO < 500ms)",
          "type": "gauge",
          "gridPos": {"h": 8, "w": 8, "x": 8, "y": 0},
          "targets": [
            {
              "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app=\"webapp\"}[5m])) by (le)) * 1000",
              "legendFormat": "P99 ms"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  {"color": "green", "value": null},
                  {"color": "yellow", "value": 300},
                  {"color": "red", "value": 500}
                ]
              },
              "unit": "ms",
              "max": 1000
            }
          }
        },
        {
          "title": "Disponibilidad (SLO > 99.5%)",
          "type": "gauge",
          "gridPos": {"h": 8, "w": 8, "x": 16, "y": 0},
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{app=\"webapp\",status=~\"2..|3..\"}[5m])) / sum(rate(http_requests_total{app=\"webapp\"}[5m])) * 100",
              "legendFormat": "Availability %"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  {"color": "red", "value": null},
                  {"color": "yellow", "value": 99},
                  {"color": "green", "value": 99.5}
                ]
              },
              "unit": "percent",
              "min": 95,
              "max": 100
            }
          }
        },
        {
          "title": "Request Rate por Status",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{app=\"webapp\"}[1m])) by (status)",
              "legendFormat": "HTTP {{status}}"
            }
          ]
        }
      ],
      "schemaVersion": 39,
      "tags": ["webapp", "slo"],
      "templating": {"list": []},
      "time": {"from": "now-1h", "to": "now"},
      "title": "Webapp SLOs",
      "uid": "webapp-slos"
    }
EOF
```

2. Aplicar el dashboard:

```bash
kubectl apply -f ~/k8s-labs/lab05/dashboards/webapp-slo-dashboard.yaml
```

**Salida esperada:**

```
configmap/webapp-slo-dashboard created
```

**Verificación:**

```bash
kubectl get configmaps -n monitoring -l grafana_dashboard=1
# Debe listar webapp-slo-dashboard
```

---

### Paso 8: Simular Incidente 1 — OOMKill

**Objetivo:** Provocar un OOMKill en un pod para validar que la alerta `PodOOMKilled` se dispara y llega al webhook receiver.

**Instrucciones:**

1. Crear un pod que consumirá toda su memoria asignada:

```bash
cat > ~/k8s-labs/lab05/incidents/oomkill-simulation.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-hog
  namespace: webapp
  labels:
    app: memory-hog
    incident: oomkill
spec:
  replicas: 1
  selector:
    matchLabels:
      app: memory-hog
  template:
    metadata:
      labels:
        app: memory-hog
        incident: oomkill
    spec:
      containers:
        - name: memory-hog
          image: python:3.11-slim
          command:
            - python3
            - -c
            - |
              import time
              data = []
              print("Starting memory leak simulation...")
              while True:
                  # Asignar ~10MB por iteración
                  data.append(' ' * (10 * 1024 * 1024))
                  print(f"Allocated {len(data) * 10} MB")
                  time.sleep(1)
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "100m"
EOF
```

2. Desplegar el pod con memory leak:

```bash
kubectl apply -f ~/k8s-labs/lab05/incidents/oomkill-simulation.yaml
```

3. Observar el OOMKill:

```bash
# Esperar hasta que el pod sea terminado por OOM (aprox. 15-30 segundos)
echo "Esperando OOMKill..."
sleep 30

kubectl get pods -n webapp -l app=memory-hog
kubectl describe pod -n webapp -l app=memory-hog | grep -A5 "Last State"
```

4. Verificar que kube-state-metrics reporta el OOMKill:

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s "http://localhost:9090/api/v1/query?query=kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\",namespace=\"webapp\"}" | python3 -m json.tool | grep -A3 "metric"
kill %1 2>/dev/null
```

5. Verificar alertas en el webhook receiver:

```bash
# Esperar a que la alerta se propague (puede tardar 2-5 minutos)
echo "Esperando propagación de alerta (2-3 min)..."
sleep 180

kubectl logs -n monitoring -l app=alertmanager-webhook --tail=20
```

**Salida esperada:**

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Y en los logs del webhook:

```
[2024-xx-xxTxx:xx:xx] Received 1 alert(s):
  - [firing] PodOOMKilled (severity: critical)
```

**Verificación:**

```bash
# Verificar que el pod está en CrashLoopBackOff o OOMKilled
kubectl get pods -n webapp -l app=memory-hog -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'
# Debe retornar: OOMKilled
```

---

### Paso 9: Simular Incidente 2 — CrashLoopBackOff

**Objetivo:** Crear un deployment que falla continuamente para disparar la alerta `PodCrashLooping`.

**Instrucciones:**

1. Crear un deployment que crashea inmediatamente:

```bash
cat > ~/k8s-labs/lab05/incidents/crashloop-simulation.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crashloop-app
  namespace: webapp
  labels:
    app: crashloop-app
    incident: crashloop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: crashloop-app
  template:
    metadata:
      labels:
        app: crashloop-app
        incident: crashloop
    spec:
      containers:
        - name: crashloop
          image: python:3.11-slim
          command:
            - python3
            - -c
            - |
              import sys
              print("ERROR: Cannot connect to database - simulated failure")
              sys.exit(1)
          resources:
            requests:
              memory: "32Mi"
              cpu: "25m"
            limits:
              memory: "64Mi"
              cpu: "50m"
EOF
```

2. Desplegar:

```bash
kubectl apply -f ~/k8s-labs/lab05/incidents/crashloop-simulation.yaml
```

3. Observar el CrashLoopBackOff:

```bash
# Esperar a que entre en CrashLoopBackOff
sleep 60
kubectl get pods -n webapp -l app=crashloop-app
```

4. Verificar el contador de restarts en Prometheus:

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s "http://localhost:9090/api/v1/query?query=increase(kube_pod_container_status_restarts_total{namespace=\"webapp\",pod=~\"crashloop.*\"}[15m])" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
for r in results:
    print(f'Pod: {r[\"metric\"].get(\"pod\", \"unknown\")} - Restarts (15m): {r[\"value\"][1]}')
"
kill %1 2>/dev/null
```

**Salida esperada:**

```
NAME                             READY   STATUS             RESTARTS      AGE
crashloop-app-xxxxx              0/1     CrashLoopBackOff   4 (10s ago)   60s
```

**Verificación:**

```bash
# Después de 5+ minutos, verificar alerta en webhook
sleep 120
kubectl logs -n monitoring -l app=alertmanager-webhook --tail=30 | grep -i "crashloop\|CrashLoop"
```

---

### Paso 10: Simular Incidente 3 — Alta Latencia

**Objetivo:** Inyectar latencia artificial en webapp para disparar la alerta `WebappHighLatency` de SLO.

**Instrucciones:**

1. Crear una versión de webapp con latencia inyectada:

```bash
cat > ~/k8s-labs/lab05/incidents/high-latency-simulation.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-slow
  namespace: webapp
  labels:
    app: webapp
    version: slow
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
      version: slow
  template:
    metadata:
      labels:
        app: webapp
        version: slow
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
        - name: webapp-slow
          image: python:3.11-slim
          ports:
            - containerPort: 8080
              name: http
          command:
            - python3
            - -c
            - |
              from http.server import HTTPServer, BaseHTTPRequestHandler
              import random, time, threading

              metrics = {
                  'http_requests_total': {},
                  'http_request_duration_seconds_bucket': {},
                  'http_request_duration_seconds_sum': 0,
                  'http_request_duration_seconds_count': 0,
                  'app_errors_total': {},
                  'app_up': 1
              }

              buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
              for b in buckets + [float('inf')]:
                  metrics['http_request_duration_seconds_bucket'][str(b)] = 0

              def simulate_slow_traffic():
                  while True:
                      method = random.choice(['GET', 'POST', 'GET', 'GET'])
                      status = random.choices(['200', '500'], weights=[90, 10])[0]
                      key = f'{method}_{status}'
                      metrics['http_requests_total'][key] = metrics['http_requests_total'].get(key, 0) + 1

                      if status == '500':
                          metrics['app_errors_total']['500'] = metrics['app_errors_total'].get('500', 0) + 1

                      # Latencia alta: media ~800ms con picos de hasta 3s
                      latency = random.uniform(0.5, 3.0)
                      metrics['http_request_duration_seconds_sum'] += latency
                      metrics['http_request_duration_seconds_count'] += 1
                      for b in buckets + [float('inf')]:
                          if latency <= b:
                              metrics['http_request_duration_seconds_bucket'][str(b)] += 1

                      time.sleep(random.uniform(0.05, 0.2))

              threading.Thread(target=simulate_slow_traffic, daemon=True).start()

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      if self.path == '/metrics':
                          lines = []
                          lines.append('# HELP http_requests_total Total HTTP requests')
                          lines.append('# TYPE http_requests_total counter')
                          for key, val in metrics['http_requests_total'].items():
                              method, status = key.split('_')
                              lines.append(f'http_requests_total{{method="{method}",status="{status}",app="webapp"}} {val}')
                          lines.append('# HELP http_request_duration_seconds Request duration')
                          lines.append('# TYPE http_request_duration_seconds histogram')
                          for b, val in metrics['http_request_duration_seconds_bucket'].items():
                              le = '+Inf' if b == 'inf' else b
                              lines.append(f'http_request_duration_seconds_bucket{{app="webapp",le="{le}"}} {val}')
                          lines.append(f'http_request_duration_seconds_sum{{app="webapp"}} {metrics["http_request_duration_seconds_sum"]:.4f}')
                          lines.append(f'http_request_duration_seconds_count{{app="webapp"}} {metrics["http_request_duration_seconds_count"]}')
                          lines.append('# HELP app_errors_total Total errors')
                          lines.append('# TYPE app_errors_total counter')
                          for key, val in metrics['app_errors_total'].items():
                              lines.append(f'app_errors_total{{status="{key}",app="webapp"}} {val}')
                          lines.append(f'# HELP app_up App health\n# TYPE app_up gauge\napp_up{{app="webapp"}} 1')
                          body = '\n'.join(lines) + '\n'
                          self.send_response(200)
                          self.send_header('Content-Type', 'text/plain')
                          self.end_headers()
                          self.wfile.write(body.encode())
                      else:
                          self.send_response(200)
                          self.end_headers()
                          self.wfile.write(b'OK')
                  def log_message(self, format, *args):
                      pass

              HTTPServer(('', 8080), Handler).serve_forever()
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
EOF
```

2. Escalar el deployment original a 0 y desplegar la versión lenta:

```bash
# Escalar webapp original a 0 para que solo la versión lenta genere métricas
kubectl scale deployment webapp -n webapp --replicas=0

# Desplegar versión con alta latencia
kubectl apply -f ~/k8s-labs/lab05/incidents/high-latency-simulation.yaml
kubectl wait --for=condition=Ready pod -l app=webapp,version=slow -n webapp --timeout=60s
```

3. Esperar a que la alerta se dispare (requiere 2 minutos de evaluación + tiempo de scraping):

```bash
echo "Esperando que la alerta de latencia se dispare (~3-4 minutos)..."
sleep 240

# Verificar alertas activas en Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s "http://localhost:9090/api/v1/alerts" | python3 -c "
import json, sys
data = json.load(sys.stdin)
alerts = data.get('data', {}).get('alerts', [])
active = [a for a in alerts if a['state'] == 'firing' and 'webapp' in a.get('labels', {}).get('alertname', '').lower()]
print(f'Alertas webapp activas: {len(active)}')
for a in active:
    print(f'  - {a[\"labels\"][\"alertname\"]} (severity: {a[\"labels\"].get(\"severity\", \"unknown\")})')
"
kill %1 2>/dev/null
```

4. Verificar recepción en webhook:

```bash
kubectl logs -n monitoring -l app=alertmanager-webhook --tail=30
```

**Salida esperada:**

```
Alertas webapp activas: 2
  - WebappHighLatency (severity: critical)
  - WebappHighErrorRate (severity: critical)
```

**Verificación:**

```bash
# Restaurar webapp original
kubectl scale deployment webapp -n webapp --replicas=2
kubectl delete deployment webapp-slow -n webapp

# Verificar resolución (las alertas deberían resolverse en ~5 min)
echo "Webapp restaurada. Las alertas se resolverán automáticamente."
```

---

### Paso 11: Validar Alertmanager Routing e Inhibition Rules

**Objetivo:** Confirmar que el routing de Alertmanager funciona correctamente y que las inhibition rules suprimen alertas según la configuración.

**Instrucciones:**

1. Verificar la configuración activa de Alertmanager:

```bash
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093 &
sleep 3

# Verificar status
curl -s http://localhost:9093/api/v2/status | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Cluster status: {data.get(\"cluster\", {}).get(\"status\", \"unknown\")}')
print(f'Uptime: {data.get(\"uptime\", \"unknown\")}')
"

# Verificar alertas activas en Alertmanager
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import json, sys
alerts = json.load(sys.stdin)
print(f'Total alertas en Alertmanager: {len(alerts)}')
for a in alerts[:10]:
    labels = a.get('labels', {})
    print(f'  [{a.get(\"status\", {}).get(\"state\", \"?\")}] {labels.get(\"alertname\", \"?\")} -> receiver: {a.get(\"receivers\", [{}])[0].get(\"name\", \"?\")}')
"

kill %1 2>/dev/null
```

2. Verificar que las inhibition rules están configuradas:

```bash
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093 &
sleep 2
curl -s http://localhost:9093/api/v2/status | python3 -c "
import json, sys, yaml
data = json.load(sys.stdin)
config = data.get('config', {}).get('original', '')
parsed = yaml.safe_load(config) if config else {}
inhibit_rules = parsed.get('inhibit_rules', [])
print(f'Inhibition rules configuradas: {len(inhibit_rules)}')
for i, rule in enumerate(inhibit_rules):
    source = rule.get('source_matchers', [])
    target = rule.get('target_matchers', [])
    print(f'  Rule {i+1}: source={source} -> target={target}')
" 2>/dev/null || echo "Verificación manual requerida via UI"
kill %1 2>/dev/null
```

**Salida esperada:**

```
Total alertas en Alertmanager: X
  [active] PodCrashLooping -> receiver: critical-webhook
  [active] WebappHighLatency -> receiver: critical-webhook
```

**Verificación:**

```bash
# Verificar logs del webhook para confirmar que recibió alertas con routing correcto
kubectl logs -n monitoring -l app=alertmanager-webhook --tail=50 | grep -c "critical"
# Debe ser > 0
```

---

## Validación y Testing

Ejecuta los siguientes comandos para validar que todo el laboratorio está correctamente configurado:

```bash
echo "=== VALIDACIÓN COMPLETA DEL LAB 05 ==="
echo ""

# 1. Verificar stack desplegado
echo "1. Componentes del stack:"
kubectl get pods -n monitoring --no-headers | wc -l
echo "   pods en monitoring (esperado: 7+)"

# 2. Verificar CRDs
echo ""
echo "2. CRDs de monitoring:"
kubectl get crd | grep -c monitoring.coreos.com
echo "   CRDs instalados (esperado: 10)"

# 3. Verificar ServiceMonitors
echo ""
echo "3. ServiceMonitors:"
kubectl get servicemonitors -A --no-headers | wc -l
echo "   ServiceMonitors totales (esperado: 5+)"

# 4. Verificar PrometheusRules
echo ""
echo "4. PrometheusRules custom:"
kubectl get prometheusrules -n monitoring --no-headers | grep -E "infrastructure|kubernetes|webapp" | wc -l
echo "   Reglas custom (esperado: 3)"

# 5. Verificar Prometheus targets
echo ""
echo "5. Prometheus targets:"
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &>/dev/null &
PF_PID=$!
sleep 3
TARGETS=$(curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
active = [t for t in data.get('data', {}).get('activeTargets', []) if t['health'] == 'up']
print(len(active))
")
echo "   Targets activos (up): $TARGETS"
kill $PF_PID 2>/dev/null

# 6. Verificar Grafana
echo ""
echo "6. Grafana:"
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &>/dev/null &
PF_PID=$!
sleep 3
GRAFANA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health)
echo "   Health status: $GRAFANA_STATUS (esperado: 200)"
kill $PF_PID 2>/dev/null

# 7. Verificar webhook recibió alertas
echo ""
echo "7. Alertas recibidas en webhook:"
kubectl logs -n monitoring -l app=alertmanager-webhook --tail=100 | grep -c "Received"
echo "   batches de alertas recibidos"

# 8. Verificar PVCs
echo ""
echo "8. Persistencia:"
kubectl get pvc -n monitoring --no-headers
echo ""
echo "=== VALIDACIÓN COMPLETADA ==="
```

---

## Troubleshooting

### Problema 1: Prometheus no descubre los targets de webapp

**Síntomas:**
- El ServiceMonitor `webapp-monitor` existe pero no aparece en la lista de targets de Prometheus.
- En `http://localhost:9090/targets` no se muestra ningún target para `serviceMonitor/webapp/webapp-monitor`.

**Causa:**
El ServiceMonitor tiene un selector de labels que no coincide con el Service de webapp, o el operador Prometheus tiene un `serviceMonitorSelector` restrictivo que filtra el ServiceMonitor.

**Solución:**

```bash
# 1. Verificar que las labels del Service coinciden con el selector del ServiceMonitor
kubectl get svc webapp -n webapp --show-labels
# Debe tener label: app=webapp

# 2. Verificar que el ServiceMonitor tiene el selector correcto
kubectl get servicemonitor webapp-monitor -n webapp -o yaml | grep -A3 "selector"

# 3. Verificar que el puerto 'metrics' existe en el Service
kubectl get svc webapp -n webapp -o jsonpath='{.spec.ports[*].name}'
# Debe incluir 'metrics'

# 4. Si el problema persiste, verificar que el operador no filtra por label 'release'
kubectl get prometheus -n monitoring -o yaml | grep -A5 "serviceMonitorSelector"
# Si serviceMonitorSelectorNilUsesHelmValues es true, añadir label:
kubectl label servicemonitor webapp-monitor -n webapp release=kube-prometheus-stack

# 5. Forzar reconciliación reiniciando el operador
kubectl rollout restart deployment kube-prometheus-stack-operator -n monitoring
```

### Problema 2: Las alertas se disparan pero no llegan al webhook receiver

**Síntomas:**
- En Prometheus UI (`/alerts`) las alertas aparecen en estado `firing`.
- En Alertmanager UI (`/api/v2/alerts`) las alertas están presentes.
- Los logs del pod `alertmanager-webhook` no muestran recepción de alertas.

**Causa:**
El Service `alertmanager-webhook` no es accesible desde Alertmanager, o la URL del receiver está mal configurada en la configuración de Alertmanager.

**Solución:**

```bash
# 1. Verificar conectividad desde Alertmanager al webhook
kubectl exec -n monitoring $(kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}') -- wget -q -O- http://alertmanager-webhook.monitoring.svc:5001/ 2>&1 || true

# 2. Verificar que el Service existe y tiene endpoints
kubectl get endpoints alertmanager-webhook -n monitoring
# Debe mostrar una IP y puerto 5001

# 3. Verificar la configuración activa de Alertmanager
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093 &
sleep 2
curl -s http://localhost:9093/api/v2/status | grep -o "alertmanager-webhook[^\"]*"
kill %1 2>/dev/null
# Debe mostrar la URL del webhook

# 4. Si la URL es incorrecta, actualizar los valores de Helm y hacer upgrade
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 61.3.0 \
  -f ~/k8s-labs/lab05/values/kube-prometheus-stack-values.yaml \
  --wait

# 5. Verificar que el pod del webhook está healthy
kubectl logs -n monitoring -l app=alertmanager-webhook | tail -5
# Debe mostrar "Webhook receiver listening on port 5001..."
```

---

## Limpieza

Para eliminar los recursos de simulación de incidentes (manteniendo el stack de monitorización para labs posteriores):

```bash
# Eliminar deployments de incidentes
kubectl delete deployment memory-hog -n webapp --ignore-not-found
kubectl delete deployment crashloop-app -n webapp --ignore-not-found
kubectl delete deployment webapp-slow -n webapp --ignore-not-found

# Restaurar webapp a estado normal
kubectl scale deployment webapp -n webapp --replicas=2

# Verificar estado limpio
kubectl get pods -n webapp
```

Para eliminar **todo** el lab (solo si no se necesita para labs posteriores):

```bash
# ADVERTENCIA: Esto eliminará todo el stack de monitorización
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
kubectl delete crd $(kubectl get crd | grep monitoring.coreos.com | awk '{print $1}')
```

---

## Resumen

En este laboratorio has completado las siguientes tareas:

| Tarea | Estado |
|-------|--------|
| Despliegue de kube-prometheus-stack 61.3.0 con persistencia | ✅ |
| Configuración de ServiceMonitor para webapp | ✅ |
| Creación de PrometheusRules agrupadas (infra, k8s, app) | ✅ |
| Configuración de Alertmanager con routing y inhibition rules | ✅ |
| Dashboard Grafana para SLOs | ✅ |
| Simulación de OOMKill | ✅ |
| Simulación de CrashLoopBackOff | ✅ |
| Simulación de alta latencia | ✅ |
| Validación del flujo completo de alerting | ✅ |

### Conceptos Clave Aplicados

- **Modelo pull de Prometheus**: scraping periódico de endpoints `/metrics` mediante ServiceMonitors
- **Cardinalidad controlada**: métricas con labels limitadas y predecibles
- **SLOs como alertas**: traducción directa de objetivos de nivel de servicio a expresiones PromQL
- **Inhibition rules**: supresión inteligente de alertas redundantes para reducir ruido operacional
- **Observabilidad proactiva**: detección automática de degradación antes del impacto al usuario

### Recursos Adicionales

- [Documentación de kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)
- [Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Google SRE Book — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
