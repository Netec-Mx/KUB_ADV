# Práctica 7 — Construir y Publicar Charts; Integrar en Pipeline CI

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Descripción General

En esta práctica diseñarás un Helm chart avanzado para la aplicación `webapp` con dependencias de subchart (PostgreSQL), helpers reutilizables y perfiles de valores por entorno. Configurarás ChartMuseum como repositorio privado, implementarás testing automatizado con helm-unittest y chart-testing, y construirás un pipeline CI/CD completo con Tekton que automatiza lint, test, empaquetado y publicación del chart ante cambios detectados en Gitea. Finalmente, implementarás hooks de Helm para rollback automatizado.

## Objetivos de Aprendizaje

- [ ] Diseñar un Helm chart con subchart dependencies, helpers `_helpers.tpl` y `values.schema.json`
- [ ] Configurar ChartMuseum y publicar múltiples versiones del chart `webapp`
- [ ] Implementar tests unitarios con helm-unittest y validación con chart-testing
- [ ] Construir un pipeline Tekton end-to-end (lint → test → package → push → deploy)
- [ ] Implementar Helm hooks para pre-upgrade, post-upgrade y pre-rollback con validación de salud

## Prerrequisitos

### Conocimientos

- Helm 3: creación de charts, templates Go, funciones Sprig
- Tekton Pipelines: Tasks, Pipelines, EventListeners
- Git básico y webhooks
- Kubernetes: Deployments, Services, Ingress, RBAC

### Acceso y Software

| Componente | Versión | Estado requerido |
|---|---|---|
| Clúster `lab-calico` (kind) | 1.30.2 | Corriendo con webapp desplegada |
| Helm | 3.15.2 | Instalado con plugins |
| helm-unittest | 0.5.1 | Plugin instalado |
| chart-testing (ct) | 3.11.0 | Binario en PATH |
| Tekton Pipelines | 0.61.0 | Aplicado al clúster |
| Tekton Triggers | 0.26.0 | Aplicado al clúster |
| tkn CLI | 0.37.0 | Instalado |
| Gitea | 1.22.0 | Corriendo en ns `gitea` |
| ChartMuseum | 0.16.2 | Corriendo en ns `helm-registry` |
| yamllint | 1.35.1 | Instalado via pip3 |

## Entorno del Laboratorio

### Preparación del directorio de trabajo

```bash
mkdir -p ~/k8s-labs/lab07/{charts/webapp,pipeline,tests}
cd ~/k8s-labs/lab07
```

### Verificar estado del clúster y servicios

```bash
kubectl cluster-info --context kind-lab-calico
kubectl get pods -n helm-registry
kubectl get pods -n gitea
kubectl get pods -n tekton-pipelines
```

### Configurar acceso a ChartMuseum

```bash
# Port-forward para acceso local (ejecutar en background)
kubectl port-forward svc/chartmuseum -n helm-registry 8081:8080 &
export CHARTMUSEUM_URL=http://localhost:8081

# Agregar repositorio a Helm
helm repo add chartmuseum $CHARTMUSEUM_URL
helm repo update
```

### Configurar acceso a Gitea

```bash
kubectl port-forward svc/gitea-http -n gitea 3000:3000 &
export GITEA_URL=http://localhost:3000
```

---

## Paso 1: Diseñar el Helm Chart Avanzado para webapp

**Objetivo:** Crear la estructura completa del chart `webapp` con dependencias, helpers reutilizables, esquema de validación y perfiles por entorno.

### Instrucciones

1. Crear la estructura de directorios del chart:

```bash
cd ~/k8s-labs/lab07/charts/webapp
mkdir -p templates tests charts
```

2. Crear `Chart.yaml` con dependencia de PostgreSQL:

```bash
cat > Chart.yaml <<'EOF'
apiVersion: v2
name: webapp
description: Chart avanzado para la aplicación webapp con PostgreSQL
type: application
version: 1.0.0
appVersion: "1.0.0"
maintainers:
  - name: platform-team
    email: platform@lab.local

dependencies:
  - name: postgresql
    version: "15.5.7"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
EOF
```

3. Crear `_helpers.tpl` con funciones reutilizables:

```bash
cat > templates/_helpers.tpl <<'EOF'
{{/*
Nombre del chart
*/}}
{{- define "webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nombre completo del release
*/}}
{{- define "webapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Nombre del chart con versión
*/}}
{{- define "webapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Etiquetas estándar
*/}}
{{- define "webapp.labels" -}}
helm.sh/chart: {{ include "webapp.chart" . }}
{{ include "webapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment | default "dev" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
URL de la base de datos
*/}}
{{- define "webapp.databaseUrl" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "postgresql://%s-postgresql:5432/%s" .Release.Name .Values.postgresql.auth.database }}
{{- else }}
{{- required "externalDatabase.url es obligatorio cuando postgresql.enabled=false" .Values.externalDatabase.url }}
{{- end }}
{{- end }}

{{/*
Imagen completa con tag
*/}}
{{- define "webapp.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
EOF
```

4. Crear `templates/deployment.yaml`:

```bash
cat > templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "webapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
      labels:
        {{- include "webapp.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: {{ include "webapp.image" . }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort | default 8080 }}
              protocol: TCP
          env:
            - name: DATABASE_URL
              value: {{ include "webapp.databaseUrl" . | quote }}
            - name: ENVIRONMENT
              value: {{ .Values.environment | default "dev" | quote }}
            {{- range .Values.extraEnv }}
            - name: {{ .name }}
              value: {{ .value | quote }}
            {{- end }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
            periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
            periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF
```

5. Crear `templates/service.yaml`:

```bash
cat > templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "webapp.selectorLabels" . | nindent 4 }}
EOF
```

6. Crear `templates/ingress.yaml`:

```bash
cat > templates/ingress.yaml <<'EOF'
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "webapp.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
EOF
```

7. Crear `templates/hpa.yaml`:

```bash
cat > templates/hpa.yaml <<'EOF'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "webapp.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
EOF
```

8. Crear `templates/pdb.yaml`:

```bash
cat > templates/pdb.yaml <<'EOF'
{{- if .Values.podDisruptionBudget.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.podDisruptionBudget.minAvailable }}
  selector:
    matchLabels:
      {{- include "webapp.selectorLabels" . | nindent 6 }}
{{- end }}
EOF
```

9. Crear `templates/configmap.yaml`:

```bash
cat > templates/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "webapp.fullname" . }}-config
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
data:
  APP_NAME: {{ include "webapp.name" . | quote }}
  APP_VERSION: {{ .Chart.AppVersion | quote }}
  ENVIRONMENT: {{ .Values.environment | default "dev" | quote }}
EOF
```

10. Crear `values.yaml` (valores por defecto — perfil dev):

```bash
cat > values.yaml <<'EOF'
# Perfil por defecto: dev
environment: dev

replicaCount: 1

image:
  repository: localhost:5000/webapp
  tag: "1.0.0"
  pullPolicy: IfNotPresent

nameOverride: ""
fullnameOverride: ""

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: true
  className: nginx
  host: webapp.lab.local
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

podDisruptionBudget:
  enabled: false
  minAvailable: 1

resources:
  limits:
    cpu: 250m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

probes:
  liveness:
    path: /healthz
    initialDelaySeconds: 10
    periodSeconds: 10
  readiness:
    path: /ready
    initialDelaySeconds: 5
    periodSeconds: 5

extraEnv: []

postgresql:
  enabled: true
  auth:
    database: webapp
    username: webapp
    password: webapp-pass
  primary:
    persistence:
      size: 1Gi

externalDatabase:
  url: ""
EOF
```

11. Crear perfiles de valores para staging y producción:

```bash
cat > values-staging.yaml <<'EOF'
environment: staging
replicaCount: 2

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 75

podDisruptionBudget:
  enabled: true
  minAvailable: 1

ingress:
  host: webapp-staging.lab.local

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 200m
    memory: 256Mi
EOF

cat > values-prod.yaml <<'EOF'
environment: prod
replicaCount: 3

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

podDisruptionBudget:
  enabled: true
  minAvailable: 2

ingress:
  host: webapp.lab.local
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "true"

resources:
  limits:
    cpu: "1"
    memory: 1Gi
  requests:
    cpu: 500m
    memory: 512Mi

postgresql:
  enabled: false

externalDatabase:
  url: "postgresql://prod-db.internal:5432/webapp"
EOF
```

12. Crear `values.schema.json`:

```bash
cat > values.schema.json <<'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["replicaCount", "image"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1
    },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string", "minLength": 1 },
        "tag": { "type": "string" },
        "pullPolicy": { "type": "string", "enum": ["Always", "IfNotPresent", "Never"] }
      }
    },
    "environment": {
      "type": "string",
      "enum": ["dev", "staging", "prod"]
    },
    "service": {
      "type": "object",
      "properties": {
        "type": { "type": "string", "enum": ["ClusterIP", "NodePort", "LoadBalancer"] },
        "port": { "type": "integer", "minimum": 1, "maximum": 65535 }
      }
    }
  }
}
EOF
```

13. Crear `templates/NOTES.txt`:

```bash
cat > templates/NOTES.txt <<'EOF'
=== webapp {{ .Chart.Version }} desplegada ===
Entorno: {{ .Values.environment | default "dev" }}
Réplicas: {{ .Values.replicaCount }}
{{- if .Values.ingress.enabled }}
URL: http://{{ .Values.ingress.host }}
{{- end }}
EOF
```

14. Descargar dependencias:

```bash
cd ~/k8s-labs/lab07/charts/webapp
helm dependency update .
```

### Salida Esperada

```
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "bitnami" chart repository
Update Complete. ⎈Happy Helming!⎈
Saving 1 charts
Downloading postgresql from repo https://charts.bitnami.com/bitnami
Deleting outdated charts
```

### Verificación

```bash
helm lint .
helm template test-release . --debug | head -50
```

El lint debe reportar `0 chart(s) failed` y el template debe renderizar correctamente.

---

## Paso 2: Implementar Tests con helm-unittest y chart-testing

**Objetivo:** Validar que las plantillas generan manifiestos correctos mediante tests unitarios y lint avanzado.

### Instrucciones

1. Crear directorio de tests unitarios:

```bash
mkdir -p ~/k8s-labs/lab07/charts/webapp/tests
```

2. Crear test para el Deployment:

```bash
cat > ~/k8s-labs/lab07/charts/webapp/tests/deployment_test.yaml <<'EOF'
suite: Deployment tests
templates:
  - deployment.yaml
tests:
  - it: debe renderizar el nombre correcto
    set:
      image.repository: localhost:5000/webapp
      image.tag: "1.0.0"
    asserts:
      - isKind:
          of: Deployment
      - matchRegex:
          path: metadata.name
          pattern: ".*-webapp$"

  - it: debe usar la imagen especificada
    set:
      image.repository: localhost:5000/webapp
      image.tag: "2.0.0"
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: "localhost:5000/webapp:2.0.0"

  - it: debe respetar replicaCount cuando autoscaling está deshabilitado
    set:
      replicaCount: 3
      autoscaling.enabled: false
      image.repository: localhost:5000/webapp
    asserts:
      - equal:
          path: spec.replicas
          value: 3

  - it: no debe establecer replicas cuando autoscaling está habilitado
    set:
      autoscaling.enabled: true
      image.repository: localhost:5000/webapp
    asserts:
      - isNull:
          path: spec.replicas

  - it: debe incluir labels estándar
    set:
      image.repository: localhost:5000/webapp
    asserts:
      - exists:
          path: metadata.labels["helm.sh/chart"]
      - exists:
          path: metadata.labels["app.kubernetes.io/managed-by"]
EOF
```

3. Crear test para el Service:

```bash
cat > ~/k8s-labs/lab07/charts/webapp/tests/service_test.yaml <<'EOF'
suite: Service tests
templates:
  - service.yaml
tests:
  - it: debe crear un Service ClusterIP por defecto
    asserts:
      - isKind:
          of: Service
      - equal:
          path: spec.type
          value: ClusterIP

  - it: debe exponer el puerto 80
    asserts:
      - equal:
          path: spec.ports[0].port
          value: 80
EOF
```

4. Crear test para el Ingress:

```bash
cat > ~/k8s-labs/lab07/charts/webapp/tests/ingress_test.yaml <<'EOF'
suite: Ingress tests
templates:
  - ingress.yaml
tests:
  - it: debe crear Ingress cuando está habilitado
    set:
      ingress.enabled: true
      ingress.host: webapp.test.local
      ingress.className: nginx
    asserts:
      - isKind:
          of: Ingress
      - equal:
          path: spec.rules[0].host
          value: webapp.test.local

  - it: no debe crear Ingress cuando está deshabilitado
    set:
      ingress.enabled: false
    asserts:
      - hasDocuments:
          count: 0
EOF
```

5. Ejecutar helm-unittest:

```bash
cd ~/k8s-labs/lab07/charts/webapp
helm unittest .
```

6. Ejecutar validación con chart-testing (lint):

```bash
# Crear configuración para ct
mkdir -p ~/k8s-labs/lab07/ct
cat > ~/k8s-labs/lab07/ct/ct.yaml <<'EOF'
chart-dirs:
  - charts
target-branch: main
helm-extra-args: --timeout 120s
validate-maintainers: false
EOF

cd ~/k8s-labs/lab07
ct lint --config ct/ct.yaml --charts charts/webapp
```

7. Validar YAML con yamllint:

```bash
cd ~/k8s-labs/lab07/charts/webapp
helm template test . | yamllint -d "{extends: default, rules: {line-length: {max: 200}}}" -
```

### Salida Esperada

```
### Chart [ webapp ] charts/webapp

 PASS  Deployment tests	tests/deployment_test.yaml
 PASS  Service tests	tests/service_test.yaml
 PASS  Ingress tests	tests/ingress_test.yaml

Charts:      1 passed, 1 total
Test Suites: 3 passed, 3 total
Tests:       8 passed, 8 total
```

### Verificación

```bash
helm unittest . --output-type JUnit --output-file ~/k8s-labs/lab07/test-results.xml
cat ~/k8s-labs/lab07/test-results.xml | grep -c 'testcase'
```

Debe mostrar al menos 8 test cases.

---

## Paso 3: Publicar el Chart en ChartMuseum

**Objetivo:** Empaquetar y publicar versiones del chart en ChartMuseum como repositorio privado.

### Instrucciones

1. Instalar plugin helm-push si no existe:

```bash
helm plugin list | grep -q "cm-push" || helm plugin install https://github.com/chartmuseum/helm-push
```

2. Empaquetar y publicar versión 1.0.0:

```bash
cd ~/k8s-labs/lab07/charts/webapp
helm package .
helm cm-push webapp-1.0.0.tgz chartmuseum
```

3. Actualizar a versión 1.1.0 (nueva feature):

```bash
# Actualizar versión en Chart.yaml
sed -i 's/^version: 1.0.0/version: 1.1.0/' Chart.yaml
sed -i 's/^appVersion: "1.0.0"/appVersion: "1.1.0"/' Chart.yaml

# Agregar nueva funcionalidad: extraLabels en deployment
cat >> templates/_helpers.tpl <<'EOF'

{{/*
Extra labels personalizadas
*/}}
{{- define "webapp.extraLabels" -}}
{{- range $key, $value := .Values.extraLabels }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}
EOF

helm package .
helm cm-push webapp-1.1.0.tgz chartmuseum
```

4. Verificar charts publicados:

```bash
helm repo update
helm search repo chartmuseum/webapp --versions
```

### Salida Esperada

```
NAME              	CHART VERSION	APP VERSION	DESCRIPTION
chartmuseum/webapp	1.1.0        	1.1.0      	Chart avanzado para la aplicación webapp...
chartmuseum/webapp	1.0.0        	1.0.0      	Chart avanzado para la aplicación webapp...
```

### Verificación

```bash
curl -s $CHARTMUSEUM_URL/api/charts/webapp | python3 -m json.tool | grep version
```

Debe listar ambas versiones (1.0.0 y 1.1.0).

---

## Paso 4: Implementar Helm Hooks para Rollback Automatizado

**Objetivo:** Crear hooks de pre-upgrade (backup), post-upgrade (smoke test) y pre-rollback (notificación) que validen la salud del despliegue.

### Instrucciones

1. Crear hook pre-upgrade (simulación de backup de BD):

```bash
cat > ~/k8s-labs/lab07/charts/webapp/templates/hook-pre-upgrade.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "webapp.fullname" . }}-pre-upgrade
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: db-backup
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              echo "[$(date)] Iniciando backup de base de datos..."
              echo "[$(date)] Simulando pg_dump de {{ include "webapp.databaseUrl" . }}"
              sleep 2
              echo "[$(date)] Backup completado exitosamente"
  backoffLimit: 1
EOF
```

2. Crear hook post-upgrade (smoke test):

```bash
cat > ~/k8s-labs/lab07/charts/webapp/templates/hook-post-upgrade.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "webapp.fullname" . }}-post-upgrade-test
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": post-upgrade,post-install
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: smoke-test
          image: curlimages/curl:8.4.0
          command:
            - /bin/sh
            - -c
            - |
              echo "Esperando que el servicio esté disponible..."
              sleep 10
              echo "Ejecutando smoke test contra {{ include "webapp.fullname" . }}:{{ .Values.service.port }}"
              RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
                http://{{ include "webapp.fullname" . }}:{{ .Values.service.port }}{{ .Values.probes.readiness.path }} \
                --max-time 30 --retry 5 --retry-delay 3)
              if [ "$RESPONSE" = "200" ]; then
                echo "Smoke test PASSED - HTTP $RESPONSE"
                exit 0
              else
                echo "Smoke test FAILED - HTTP $RESPONSE"
                exit 1
              fi
  backoffLimit: 2
EOF
```

3. Crear hook pre-rollback (notificación):

```bash
cat > ~/k8s-labs/lab07/charts/webapp/templates/hook-pre-rollback.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "webapp.fullname" . }}-pre-rollback
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-rollback
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: notify-rollback
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              echo "[ALERT] $(date) - Iniciando ROLLBACK de {{ include "webapp.fullname" . }}"
              echo "[ALERT] Release: {{ .Release.Name }}, Revision: {{ .Release.Revision }}"
              echo "[ALERT] Notificación enviada al equipo de operaciones"
  backoffLimit: 1
EOF
```

4. Validar que los hooks se renderizan correctamente:

```bash
cd ~/k8s-labs/lab07/charts/webapp
helm template test . --show-only templates/hook-pre-upgrade.yaml
helm template test . --show-only templates/hook-post-upgrade.yaml
helm template test . --show-only templates/hook-pre-rollback.yaml
```

5. Actualizar versión y empaquetar con hooks:

```bash
sed -i 's/^version: 1.1.0/version: 1.2.0/' Chart.yaml
sed -i 's/^appVersion: "1.1.0"/appVersion: "1.2.0"/' Chart.yaml
helm package .
helm cm-push webapp-1.2.0.tgz chartmuseum
helm repo update
```

### Salida Esperada

Los templates de hooks deben mostrar las anotaciones `helm.sh/hook` correctamente y la versión 1.2.0 debe aparecer en ChartMuseum.

### Verificación

```bash
helm search repo chartmuseum/webapp --versions | grep -c webapp
```

Debe mostrar 3 (versiones 1.0.0, 1.1.0, 1.2.0).

---

## Paso 5: Crear el Repositorio en Gitea y Configurar el Código

**Objetivo:** Crear el repositorio `webapp-chart` en Gitea y subir el chart para que el pipeline Tekton pueda detectar cambios.

### Instrucciones

1. Crear el repositorio en Gitea via API:

```bash
curl -X POST "$GITEA_URL/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "gitea-admin:Gitea2024!" \
  -d '{
    "name": "webapp-chart",
    "description": "Helm chart para webapp",
    "private": false,
    "auto_init": true
  }'
```

2. Clonar y subir el chart:

```bash
cd ~/k8s-labs/lab07
git clone http://gitea-admin:Gitea2024!@localhost:3000/gitea-admin/webapp-chart.git repo-webapp-chart
cp -r charts/webapp/* repo-webapp-chart/
cd repo-webapp-chart
git add -A
git commit -m "feat: chart webapp v1.2.0 con hooks y tests"
git push origin main
```

3. Crear archivo `ct.yaml` en el repo para chart-testing:

```bash
cat > ct.yaml <<'EOF'
chart-dirs:
  - .
target-branch: main
validate-maintainers: false
EOF
git add ct.yaml && git commit -m "chore: add ct config" && git push origin main
```

### Salida Esperada

```
To http://localhost:3000/gitea-admin/webapp-chart.git
   abc1234..def5678  main -> main
```

### Verificación

```bash
curl -s "$GITEA_URL/api/v1/repos/gitea-admin/webapp-chart" \
  -u "gitea-admin:Gitea2024!" | python3 -m json.tool | grep '"name"'
```

---

## Paso 6: Construir el Pipeline CI con Tekton

**Objetivo:** Crear Tasks y Pipeline de Tekton que automaticen lint, test, empaquetado y publicación del chart.

### Instrucciones

1. Crear el namespace y ServiceAccount para el pipeline:

```bash
cd ~/k8s-labs/lab07/pipeline

cat > sa-pipeline.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-sa
  namespace: webapp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pipeline-sa-admin
subjects:
  - kind: ServiceAccount
    name: pipeline-sa
    namespace: webapp
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f sa-pipeline.yaml
```

2. Crear PersistentVolumeClaim para workspace compartido:

```bash
cat > pvc-workspace.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: chart-workspace
  namespace: webapp
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
kubectl apply -f pvc-workspace.yaml
```

3. Crear Task `git-clone`:

```bash
cat > task-git-clone.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: git-clone-chart
  namespace: webapp
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
  workspaces:
    - name: output
  steps:
    - name: clone
      image: alpine/git:2.43.0
      script: |
        #!/bin/sh
        set -ex
        cd $(workspaces.output.path)
        rm -rf *
        git clone $(params.repo-url) .
        git checkout $(params.revision)
        echo "Clonado $(params.repo-url) en revision $(params.revision)"
        ls -la
EOF
kubectl apply -f task-git-clone.yaml
```

4. Crear Task `helm-lint`:

```bash
cat > task-helm-lint.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: helm-lint
  namespace: webapp
spec:
  workspaces:
    - name: source
  steps:
    - name: lint
      image: alpine/helm:3.15.2
      script: |
        #!/bin/sh
        set -ex
        cd $(workspaces.source.path)
        helm dependency update .
        helm lint . --strict
        echo "Helm lint PASSED"
EOF
kubectl apply -f task-helm-lint.yaml
```

5. Crear Task `helm-unittest`:

```bash
cat > task-helm-unittest.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: helm-unittest
  namespace: webapp
spec:
  workspaces:
    - name: source
  steps:
    - name: unittest
      image: helmunittest/helm-unittest:3.15.2-0.5.1
      script: |
        #!/bin/sh
        set -ex
        cd $(workspaces.source.path)
        helm dependency update .
        helm unittest .
        echo "Helm unittest PASSED"
EOF
kubectl apply -f task-helm-unittest.yaml
```

6. Crear Task `helm-package-push`:

```bash
cat > task-helm-package-push.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: helm-package-push
  namespace: webapp
spec:
  params:
    - name: chartmuseum-url
      type: string
      default: "http://chartmuseum.helm-registry.svc.cluster.local:8080"
  workspaces:
    - name: source
  steps:
    - name: package-and-push
      image: alpine/helm:3.15.2
      script: |
        #!/bin/sh
        set -ex
        cd $(workspaces.source.path)
        
        # Instalar plugin cm-push
        helm plugin install https://github.com/chartmuseum/helm-push || true
        
        # Agregar repo ChartMuseum
        helm repo add cm $(params.chartmuseum-url) || true
        helm repo update
        
        # Empaquetar
        helm dependency update .
        helm package .
        
        # Obtener nombre del archivo generado
        CHART_FILE=$(ls *.tgz | head -1)
        echo "Publicando $CHART_FILE"
        
        # Push al repositorio
        helm cm-push $CHART_FILE cm
        echo "Chart publicado exitosamente en ChartMuseum"
EOF
kubectl apply -f task-helm-package-push.yaml
```

7. Crear Task `helm-upgrade-release`:

```bash
cat > task-helm-upgrade.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: helm-upgrade-release
  namespace: webapp
spec:
  params:
    - name: release-name
      type: string
      default: webapp
    - name: namespace
      type: string
      default: webapp
    - name: values-file
      type: string
      default: values.yaml
  workspaces:
    - name: source
  steps:
    - name: upgrade
      image: alpine/helm:3.15.2
      script: |
        #!/bin/sh
        set -ex
        cd $(workspaces.source.path)
        helm dependency update .
        helm upgrade --install $(params.release-name) . \
          -f $(params.values-file) \
          --namespace $(params.namespace) \
          --wait \
          --timeout 120s \
          --atomic
        echo "Release $(params.release-name) actualizado exitosamente"
EOF
kubectl apply -f task-helm-upgrade.yaml
```

8. Crear el Pipeline completo:

```bash
cat > pipeline-webapp-chart.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: webapp-chart-ci
  namespace: webapp
spec:
  params:
    - name: repo-url
      type: string
      default: "http://gitea-http.gitea.svc.cluster.local:3000/gitea-admin/webapp-chart.git"
    - name: revision
      type: string
      default: main
    - name: chartmuseum-url
      type: string
      default: "http://chartmuseum.helm-registry.svc.cluster.local:8080"
  workspaces:
    - name: shared-workspace
  tasks:
    - name: fetch-source
      taskRef:
        name: git-clone-chart
      params:
        - name: repo-url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)
      workspaces:
        - name: output
          workspace: shared-workspace

    - name: lint
      taskRef:
        name: helm-lint
      runAfter:
        - fetch-source
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: unit-test
      taskRef:
        name: helm-unittest
      runAfter:
        - lint
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: package-publish
      taskRef:
        name: helm-package-push
      params:
        - name: chartmuseum-url
          value: $(params.chartmuseum-url)
      runAfter:
        - unit-test
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: deploy-dev
      taskRef:
        name: helm-upgrade-release
      params:
        - name: release-name
          value: webapp
        - name: namespace
          value: webapp
        - name: values-file
          value: values.yaml
      runAfter:
        - package-publish
      workspaces:
        - name: source
          workspace: shared-workspace
EOF
kubectl apply -f pipeline-webapp-chart.yaml
```

9. Ejecutar el pipeline manualmente para validar:

```bash
cat > pipelinerun-manual.yaml <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: webapp-chart-ci-run-
  namespace: webapp
spec:
  pipelineRef:
    name: webapp-chart-ci
  params:
    - name: repo-url
      value: "http://gitea-http.gitea.svc.cluster.local:3000/gitea-admin/webapp-chart.git"
    - name: revision
      value: main
  workspaces:
    - name: shared-workspace
      persistentVolumeClaim:
        claimName: chart-workspace
  taskRunTemplate:
    serviceAccountName: pipeline-sa
EOF
kubectl create -f pipelinerun-manual.yaml
```

10. Monitorear la ejecución:

```bash
# Obtener nombre del PipelineRun
PRUN=$(kubectl get pipelinerun -n webapp --sort-by=.metadata.creationTimestamp -o name | tail -1)
tkn pipelinerun logs ${PRUN#*/} -n webapp -f
```

### Salida Esperada

```
[fetch-source : clone] Clonado http://gitea-http... en revision main
[lint : lint] ==> Linting .
[lint : lint] 1 chart(s) linted, 0 chart(s) failed
[lint : lint] Helm lint PASSED
[unit-test : unittest] PASS  ...
[unit-test : unittest] Helm unittest PASSED
[package-publish : package-and-push] Chart publicado exitosamente en ChartMuseum
[deploy-dev : upgrade] Release webapp actualizado exitosamente
```

### Verificación

```bash
tkn pipelinerun list -n webapp
kubectl get pipelinerun -n webapp -o jsonpath='{.items[-1].status.conditions[0].status}'
```

Debe mostrar `True` (éxito).

---

## Paso 7: Configurar Tekton Triggers para Webhooks de Gitea

**Objetivo:** Automatizar la ejecución del pipeline cuando se detectan cambios en el repositorio Gitea mediante webhooks.

### Instrucciones

1. Crear el EventListener y TriggerTemplate:

```bash
cat > ~/k8s-labs/lab07/pipeline/triggers.yaml <<'EOF'
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: webapp-chart-trigger-template
  namespace: webapp
spec:
  params:
    - name: git-revision
      default: main
    - name: git-repo-url
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: webapp-chart-ci-triggered-
      spec:
        pipelineRef:
          name: webapp-chart-ci
        params:
          - name: repo-url
            value: $(tt.params.git-repo-url)
          - name: revision
            value: $(tt.params.git-revision)
        workspaces:
          - name: shared-workspace
            persistentVolumeClaim:
              claimName: chart-workspace
        taskRunTemplate:
          serviceAccountName: pipeline-sa
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: webapp-chart-trigger-binding
  namespace: webapp
spec:
  params:
    - name: git-revision
      value: $(body.after)
    - name: git-repo-url
      value: $(body.repository.clone_url)
---
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: webapp-chart-listener
  namespace: webapp
spec:
  serviceAccountName: pipeline-sa
  triggers:
    - name: gitea-push
      bindings:
        - ref: webapp-chart-trigger-binding
      template:
        ref: webapp-chart-trigger-template
EOF
kubectl apply -f ~/k8s-labs/lab07/pipeline/triggers.yaml
```

2. Verificar que el EventListener está corriendo:

```bash
kubectl get eventlistener -n webapp
kubectl get svc -n webapp | grep el-webapp-chart-listener
```

3. Configurar webhook en Gitea (apuntando al EventListener):

```bash
EL_SVC=$(kubectl get svc -n webapp -l eventlistener=webapp-chart-listener -o jsonpath='{.items[0].metadata.name}')

curl -X POST "$GITEA_URL/api/v1/repos/gitea-admin/webapp-chart/hooks" \
  -H "Content-Type: application/json" \
  -u "gitea-admin:Gitea2024!" \
  -d "{
    \"type\": \"gitea\",
    \"active\": true,
    \"config\": {
      \"url\": \"http://${EL_SVC}.webapp.svc.cluster.local:8080\",
      \"content_type\": \"json\"
    },
    \"events\": [\"push\"]
  }"
```

4. Simular un push para disparar el pipeline:

```bash
cd ~/k8s-labs/lab07/repo-webapp-chart
echo "# Trigger CI" >> README.md
git add -A && git commit -m "ci: trigger pipeline" && git push origin main
```

5. Verificar que se creó un nuevo PipelineRun:

```bash
sleep 5
tkn pipelinerun list -n webapp --limit 3
```

### Salida Esperada

```
NAME                                STARTED         DURATION   STATUS
webapp-chart-ci-triggered-xxxxx     5 seconds ago   ---        Running
webapp-chart-ci-run-xxxxx           2 minutes ago   1m30s      Succeeded
```

### Verificación

```bash
kubectl get pipelinerun -n webapp --sort-by=.metadata.creationTimestamp | tail -2
```

---

## Paso 8: Simular Release Fallida (1.2.0-broken)

**Objetivo:** Demostrar que el pipeline detecta errores en tests y no publica charts defectuosos.

### Instrucciones

1. Crear una versión rota del chart:

```bash
cd ~/k8s-labs/lab07/repo-webapp-chart

# Romper el schema: usar string donde se espera integer
sed -i 's/^version: 1.2.0/version: 1.2.0-broken/' Chart.yaml

# Introducir error en test: cambiar expectativa
cat > tests/broken_test.yaml <<'EOF'
suite: Broken test - should fail
templates:
  - deployment.yaml
tests:
  - it: debe fallar intencionalmente
    set:
      image.repository: localhost:5000/webapp
    asserts:
      - equal:
          path: metadata.name
          value: "nombre-que-no-existe-jamas"
EOF

git add -A
git commit -m "feat: version 1.2.0-broken (intentional failure)"
git push origin main
```

2. Monitorear el pipeline disparado:

```bash
sleep 10
LATEST_RUN=$(kubectl get pipelinerun -n webapp --sort-by=.metadata.creationTimestamp -o name | tail -1)
tkn pipelinerun logs ${LATEST_RUN#*/} -n webapp -f
```

3. Verificar que el pipeline falló en la fase de tests:

```bash
kubectl get pipelinerun -n webapp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].status.conditions[0].reason}'
```

4. Confirmar que la versión rota NO se publicó:

```bash
helm repo update
helm search repo chartmuseum/webapp --versions | grep "1.2.0-broken" || echo "VERSION ROTA NO PUBLICADA - CORRECTO"
```

5. Revertir el cambio para dejar el repo limpio:

```bash
cd ~/k8s-labs/lab07/repo-webapp-chart
git revert HEAD --no-edit
rm -f tests/broken_test.yaml
sed -i 's/^version: 1.2.0-broken/version: 1.2.0/' Chart.yaml
git add -A
git commit --amend -m "revert: restaurar chart funcional v1.2.0"
git push origin main --force
```

### Salida Esperada

```
[unit-test : unittest] FAIL  Broken test - should fail
...
Failed
VERSION ROTA NO PUBLICADA - CORRECTO
```

### Verificación

```bash
helm search repo chartmuseum/webapp --versions | wc -l
```

Debe mostrar 4 líneas (header + 3 versiones válidas: 1.0.0, 1.1.0, 1.2.0).

---

## Validación y Testing Final

Ejecutar la siguiente secuencia de verificaciones para confirmar que todo el laboratorio funciona correctamente:

```bash
echo "=== VALIDACIÓN COMPLETA DEL LAB 07 ==="

echo "1. Verificar estructura del chart:"
ls ~/k8s-labs/lab07/charts/webapp/{Chart.yaml,values.yaml,values.schema.json,templates/_helpers.tpl}

echo "2. Verificar dependencias descargadas:"
ls ~/k8s-labs/lab07/charts/webapp/charts/ | grep postgresql

echo "3. Verificar tests unitarios pasan:"
cd ~/k8s-labs/lab07/charts/webapp && helm unittest . 2>&1 | tail -3

echo "4. Verificar charts en ChartMuseum:"
helm search repo chartmuseum/webapp --versions

echo "5. Verificar pipeline Tekton existe:"
tkn pipeline list -n webapp

echo "6. Verificar PipelineRuns ejecutados:"
tkn pipelinerun list -n webapp --limit 5

echo "7. Verificar EventListener activo:"
kubectl get eventlistener -n webapp -o jsonpath='{.items[0].status.conditions[0].status}'

echo "8. Verificar hooks renderizados:"
cd ~/k8s-labs/lab07/charts/webapp && helm template test . --show-only templates/hook-post-upgrade.yaml | grep "helm.sh/hook"

echo "=== VALIDACIÓN COMPLETADA ==="
```

**Resultado esperado:** Todos los puntos deben mostrar información válida sin errores.

---

## Solución de Problemas

### Problema 1: helm-unittest falla con "no such file or directory" para dependencias

**Síntomas:**
```
Error: chart "webapp" has missing dependencies: postgresql
```

**Causa:** Las dependencias no se descargaron antes de ejecutar los tests. El directorio `charts/` está vacío o no contiene el `.tgz` de postgresql.

**Solución:**
```bash
cd ~/k8s-labs/lab07/charts/webapp
helm dependency update .
# Verificar que existe el archivo
ls charts/postgresql-*.tgz
# Re-ejecutar tests
helm unittest .
```

### Problema 2: El EventListener no recibe webhooks de Gitea

**Síntomas:** Tras hacer push a Gitea, no se crea ningún PipelineRun nuevo. Los logs del EventListener no muestran actividad.

**Causa:** La URL del webhook en Gitea apunta a un servicio inaccesible desde la red del pod de Gitea. Los servicios entre namespaces requieren el FQDN completo `<svc>.<namespace>.svc.cluster.local`.

**Solución:**
```bash
# Verificar el nombre del servicio del EventListener
kubectl get svc -n webapp -l eventlistener=webapp-chart-listener

# Verificar conectividad desde un pod en el namespace gitea
kubectl run test-curl --rm -i --restart=Never -n gitea \
  --image=curlimages/curl:8.4.0 -- \
  curl -v http://el-webapp-chart-listener.webapp.svc.cluster.local:8080

# Si falla, actualizar el webhook en Gitea con la URL correcta
EL_SVC_NAME=$(kubectl get svc -n webapp -l eventlistener=webapp-chart-listener -o jsonpath='{.items[0].metadata.name}')
echo "URL correcta: http://${EL_SVC_NAME}.webapp.svc.cluster.local:8080"

# Listar hooks y actualizar
HOOK_ID=$(curl -s "$GITEA_URL/api/v1/repos/gitea-admin/webapp-chart/hooks" \
  -u "gitea-admin:Gitea2024!" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -X PATCH "$GITEA_URL/api/v1/repos/gitea-admin/webapp-chart/hooks/$HOOK_ID" \
  -H "Content-Type: application/json" \
  -u "gitea-admin:Gitea2024!" \
  -d "{\"config\": {\"url\": \"http://${EL_SVC_NAME}.webapp.svc.cluster.local:8080\", \"content_type\": \"json\"}}"
```

---

## Limpieza

```bash
# Detener port-forwards
pkill -f "port-forward.*chartmuseum" || true
pkill -f "port-forward.*gitea" || true

# Eliminar PipelineRuns antiguos (conservar los últimos 2)
tkn pipelinerun delete -n webapp --keep 2 -f

# Eliminar recursos de triggers si se desea
# kubectl delete -f ~/k8s-labs/lab07/pipeline/triggers.yaml

# Eliminar workspace PVC (opcional)
# kubectl delete pvc chart-workspace -n webapp

echo "Limpieza completada. Los charts publicados en ChartMuseum se conservan para Lab 10."
```

> **Nota:** No eliminar los charts de ChartMuseum ni el repositorio de Gitea, ya que serán utilizados en el Lab 10 para el plan de recuperación ante desastres.

---

## Resumen

En esta práctica has completado el ciclo completo de empaquetado y distribución de aplicaciones Kubernetes con Helm:

| Logro | Detalle |
|-------|---------|
| **Chart avanzado** | Estructura con subchart PostgreSQL, helpers, schema JSON, perfiles por entorno |
| **Testing** | 8+ tests unitarios con helm-unittest, validación con ct lint y yamllint |
| **Repositorio privado** | ChartMuseum con 3 versiones publicadas (1.0.0, 1.1.0, 1.2.0) |
| **Pipeline CI/CD** | 5 Tasks Tekton encadenadas: clone → lint → test → publish → deploy |
| **Automatización** | EventListener + webhook Gitea para disparo automático |
| **Calidad** | Versión rota detectada y bloqueada antes de publicación |
| **Resiliencia** | Hooks pre-upgrade, post-upgrade y pre-rollback implementados |

### Recursos Adicionales

- [Helm Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Tekton Pipelines Documentation](https://tekton.dev/docs/pipelines/)
- [helm-unittest Plugin](https://github.com/helm-unittest/helm-unittest)
- [ChartMuseum API](https://chartmuseum.com/docs/)
