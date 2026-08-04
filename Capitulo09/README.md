# Práctica 9 — Crear Políticas OPA/Gatekeeper y Validar Enforcement

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |
| **Clúster** | kind-lab-calico |
| **Directorio de trabajo** | `~/k8s-labs/lab09/` |

## Descripción General

En este laboratorio implementarás una capa completa de governance sobre el clúster Kubernetes endurecido de labs anteriores. Instalarás OPA Gatekeeper 3.16.3 y crearás cinco ConstraintTemplates en Rego con sus Constraints correspondientes para controlar labels obligatorios, registries permitidos, contenedores privilegiados, límites de recursos e Ingress TLS. Complementarás con Kyverno 1.12.5 para mutación automática, validación de tags y generación de NetworkPolicies. Finalmente, configurarás auditoría continua con métricas exportadas a Prometheus.

## Objetivos de Aprendizaje

- [ ] Instalar OPA Gatekeeper 3.16.3 y crear ConstraintTemplates con Rego para políticas de governance
- [ ] Implementar Constraints con enforcement `deny` y `warn` para validar labels, registries, privilegios, limits y TLS
- [ ] Instalar Kyverno 1.12.5 y crear ClusterPolicies de mutación, validación y generación
- [ ] Configurar auditoría de Gatekeeper y visualizar violaciones en recursos existentes
- [ ] Integrar métricas de compliance con Prometheus y definir alertas para cumplimiento < 95%

## Prerrequisitos

### Conocimientos

- Comprensión del pipeline de admisión de Kubernetes (webhooks validadores y mutadores)
- Conocimiento básico del lenguaje Rego (sintaxis de paquetes, reglas y funciones)
- Labs 01-08 completados (clúster `lab-calico` operativo con Prometheus en namespace `monitoring`)

### Acceso y Herramientas

- Clúster `kind-lab-calico` activo con contexto `kind-lab-calico`
- Helm 3.15.2 instalado
- Registry local en `localhost:5000`
- Prometheus operativo en namespace `monitoring` (Lab 05)
- Acceso a Internet para descargar charts de Helm

## Entorno del Laboratorio

### Software Requerido

| Componente | Versión | Propósito |
|-----------|---------|-----------|
| OPA Gatekeeper | 3.16.3 | Motor de políticas con CRDs |
| Kyverno | 1.12.5 | Políticas en YAML nativo |
| OPA CLI | 0.66.0 | Testing local de políticas Rego |
| Helm | 3.15.2 | Instalación de charts |
| Prometheus | 2.53.0 | Métricas de compliance |

### Preparación Inicial

```bash
# Crear directorio de trabajo
mkdir -p ~/k8s-labs/lab09/{gatekeeper,kyverno,tests,metrics}
cd ~/k8s-labs/lab09/

# Verificar contexto del clúster
kubectl config use-context kind-lab-calico
kubectl cluster-info

# Añadir repos Helm necesarios
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

# Instalar OPA CLI para testing local
curl -L -o /usr/local/bin/opa https://openpolicyagent.org/downloads/v0.66.0/opa_linux_amd64_static
chmod +x /usr/local/bin/opa
opa version
```

---

## Paso 1: Instalar OPA Gatekeeper 3.16.3

**Objetivo:** Desplegar Gatekeeper como controlador de admisión con auditoría habilitada.

### Instrucciones

1. Crear el archivo de valores para la instalación de Gatekeeper:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/values.yaml << 'EOF'
replicas: 1
auditInterval: 60
auditFromCache: true
auditChunkSize: 500
constraintViolationsLimit: 100
auditMatchKindOnly: false
emitAdmissionEvents: true
emitAuditEvents: true
logLevel: INFO
metricsBackends:
  - prometheus
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8888"
EOF
```

2. Instalar Gatekeeper con Helm:

```bash
helm install gatekeeper gatekeeper/gatekeeper \
  --version 3.16.3 \
  --namespace gatekeeper-system \
  --create-namespace \
  --values ~/k8s-labs/lab09/gatekeeper/values.yaml \
  --wait --timeout 120s
```

3. Verificar la instalación:

```bash
kubectl get pods -n gatekeeper-system
kubectl get svc -n gatekeeper-system
```

### Salida Esperada

```
NAME                                             READY   STATUS    RESTARTS   AGE
gatekeeper-audit-xxxxxxxxx-xxxxx                 1/1     Running   0          30s
gatekeeper-controller-manager-xxxxxxxxx-xxxxx    1/1     Running   0          30s
```

### Verificación

```bash
# Confirmar que los webhooks están registrados
kubectl get validatingwebhookconfigurations | grep gatekeeper
# Debe mostrar: gatekeeper-validating-webhook-configuration

# Verificar CRDs instalados
kubectl get crd | grep gatekeeper
# Debe mostrar: constrainttemplates.templates.gatekeeper.sh y configs.config.gatekeeper.sh
```

---

## Paso 2: Crear ConstraintTemplates en Rego

**Objetivo:** Definir cinco plantillas de política reutilizables usando el lenguaje Rego.

### Instrucciones

1. Crear la ConstraintTemplate `K8sRequiredLabels`:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/ct-required-labels.yaml << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{"msg": msg, "details": {"missing_labels": missing}}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("El recurso '%v' debe tener las labels: %v. Faltan: %v", [input.review.object.metadata.name, required, missing])
        }
EOF
```

2. Crear la ConstraintTemplate `K8sAllowedRegistries`:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/ct-allowed-registries.yaml << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not registry_allowed(container.image)
          msg := sprintf("La imagen '%v' del contenedor '%v' no proviene de un registry permitido. Permitidos: %v", [container.image, container.name, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          not registry_allowed(container.image)
          msg := sprintf("La imagen '%v' del initContainer '%v' no proviene de un registry permitido. Permitidos: %v", [container.image, container.name, input.parameters.registries])
        }

        registry_allowed(image) {
          registry := input.parameters.registries[_]
          startswith(image, registry)
        }
EOF
```

3. Crear la ConstraintTemplate `K8sNoPrivilegedContainers`:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/ct-no-privileged.yaml << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8snoprivilegedcontainers
spec:
  crd:
    spec:
      names:
        kind: K8sNoPrivilegedContainers
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8snoprivilegedcontainers

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          container.securityContext.privileged == true
          msg := sprintf("El contenedor '%v' no puede ejecutarse en modo privilegiado.", [container.name])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          container.securityContext.privileged == true
          msg := sprintf("El initContainer '%v' no puede ejecutarse en modo privilegiado.", [container.name])
        }
EOF
```

4. Crear la ConstraintTemplate `K8sResourceLimitsRequired`:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/ct-resource-limits.yaml << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sresourcelimitsrequired
spec:
  crd:
    spec:
      names:
        kind: K8sResourceLimitsRequired
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sresourcelimitsrequired

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.cpu
          msg := sprintf("El contenedor '%v' debe definir limits de CPU.", [container.name])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.memory
          msg := sprintf("El contenedor '%v' debe definir limits de memoria.", [container.name])
        }
EOF
```

5. Crear la ConstraintTemplate `K8sIngressTLSRequired`:

```bash
cat > ~/k8s-labs/lab09/gatekeeper/ct-ingress-tls.yaml << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8singresstlsrequired
spec:
  crd:
    spec:
      names:
        kind: K8sIngressTLSRequired
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8singresstlsrequired

        violation[{"msg": msg}] {
          input.review.object.kind == "Ingress"
          not input.review.object.spec.tls
          msg := sprintf("El Ingress '%v' debe configurar TLS.", [input.review.object.metadata.name])
        }

        violation[{"msg": msg}] {
          input.review.object.kind == "Ingress"
          tls := input.review.object.spec.tls
          count(tls) == 0
          msg := sprintf("El Ingress '%v' debe tener al menos una entrada TLS.", [input.review.object.metadata.name])
        }
EOF
```

6. Aplicar todas las ConstraintTemplates:

```bash
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-required-labels.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-allowed-registries.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-no-privileged.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-resource-limits.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-ingress-tls.yaml
```

### Salida Esperada

```
constrainttemplate.templates.gatekeeper.sh/k8srequiredlabels created
constrainttemplate.templates.gatekeeper.sh/k8sallowedregistries created
constrainttemplate.templates.gatekeeper.sh/k8snoprivilegedcontainers created
constrainttemplate.templates.gatekeeper.sh/k8sresourcelimitsrequired created
constrainttemplate.templates.gatekeeper.sh/k8singresstlsrequired created
```

### Verificación

```bash
# Verificar que todas las templates están creadas y sin errores
kubectl get constrainttemplates
# Debe mostrar 5 templates con STATUS "True" en la columna CREATED

# Verificar que los CRDs correspondientes se crearon automáticamente
kubectl get crd | grep constraints.gatekeeper.sh
```

---

## Paso 3: Probar Políticas Rego Localmente con OPA CLI

**Objetivo:** Validar la lógica Rego antes de aplicar Constraints al clúster.

### Instrucciones

1. Crear un archivo de test para la política de labels:

```bash
mkdir -p ~/k8s-labs/lab09/tests/

cat > ~/k8s-labs/lab09/tests/required_labels.rego << 'EOF'
package k8srequiredlabels

violation[{"msg": msg, "details": {"missing_labels": missing}}] {
  provided := {label | input.review.object.metadata.labels[label]}
  required := {label | label := input.parameters.labels[_]}
  missing := required - provided
  count(missing) > 0
  msg := sprintf("El recurso '%v' debe tener las labels: %v. Faltan: %v", [input.review.object.metadata.name, required, missing])
}
EOF
```

2. Crear un input de prueba que viole la política:

```bash
cat > ~/k8s-labs/lab09/tests/input_violation.json << 'EOF'
{
  "review": {
    "object": {
      "metadata": {
        "name": "test-pod",
        "labels": {
          "app": "nginx"
        }
      }
    }
  },
  "parameters": {
    "labels": ["app", "version", "team", "env"]
  }
}
EOF
```

3. Evaluar la política localmente:

```bash
cd ~/k8s-labs/lab09/tests/
opa eval --data required_labels.rego --input input_violation.json "data.k8srequiredlabels.violation"
```

### Salida Esperada

```json
{
  "result": [
    {
      "expressions": [
        {
          "value": [
            {
              "details": {"missing_labels": ["env", "team", "version"]},
              "msg": "El recurso 'test-pod' debe tener las labels: {\"app\", \"env\", \"team\", \"version\"}. Faltan: {\"env\", \"team\", \"version\"}"
            }
          ]
        }
      ]
    }
  ]
}
```

### Verificación

```bash
# Probar con un input que cumple todas las labels
cat > ~/k8s-labs/lab09/tests/input_compliant.json << 'EOF'
{
  "review": {
    "object": {
      "metadata": {
        "name": "test-pod",
        "labels": {
          "app": "nginx",
          "version": "v1.0",
          "team": "platform",
          "env": "production"
        }
      }
    }
  },
  "parameters": {
    "labels": ["app", "version", "team", "env"]
  }
}
EOF

opa eval --data required_labels.rego --input input_compliant.json "data.k8srequiredlabels.violation"
# Debe devolver un set vacío: "value": []
```

---

## Paso 4: Crear Constraints y Aplicar Enforcement

**Objetivo:** Instanciar las ConstraintTemplates con parámetros concretos y activar el enforcement.

### Instrucciones

1. Crear Constraint para labels obligatorios (modo `deny` para Deployments en namespace `webapp`):

```bash
cat > ~/k8s-labs/lab09/gatekeeper/constraint-required-labels.yaml << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: deployments-must-have-labels
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
    namespaces: ["webapp"]
  parameters:
    labels:
      - "app"
      - "version"
      - "team"
      - "env"
EOF
```

2. Crear Constraint para registries permitidos (modo `deny`):

```bash
cat > ~/k8s-labs/lab09/gatekeeper/constraint-allowed-registries.yaml << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: only-approved-registries
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
      - kyverno
      - monitoring
      - ingress-nginx
      - cert-manager
      - local-path-storage
  parameters:
    registries:
      - "localhost:5000/"
      - "registry.k8s.io/"
EOF
```

3. Crear Constraint para contenedores privilegiados (modo `deny`):

```bash
cat > ~/k8s-labs/lab09/gatekeeper/constraint-no-privileged.yaml << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sNoPrivilegedContainers
metadata:
  name: no-privileged-containers
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
      - calico-system
      - calico-apiserver
EOF
```

4. Crear Constraint para resource limits (modo `warn`):

```bash
cat > ~/k8s-labs/lab09/gatekeeper/constraint-resource-limits.yaml << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sResourceLimitsRequired
metadata:
  name: containers-must-have-limits
spec:
  enforcementAction: warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
      - kyverno
      - monitoring
EOF
```

5. Crear Constraint para Ingress TLS (modo `deny`):

```bash
cat > ~/k8s-labs/lab09/gatekeeper/constraint-ingress-tls.yaml << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sIngressTLSRequired
metadata:
  name: ingress-must-have-tls
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: ["networking.k8s.io"]
        kinds: ["Ingress"]
EOF
```

6. Aplicar todos los Constraints:

```bash
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/constraint-required-labels.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/constraint-allowed-registries.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/constraint-no-privileged.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/constraint-resource-limits.yaml
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/constraint-ingress-tls.yaml
```

### Salida Esperada

```
k8srequiredlabels.constraints.gatekeeper.sh/deployments-must-have-labels created
k8sallowedregistries.constraints.gatekeeper.sh/only-approved-registries created
k8snoprivilegedcontainers.constraints.gatekeeper.sh/no-privileged-containers created
k8sresourcelimitsrequired.constraints.gatekeeper.sh/containers-must-have-limits created
k8singresstlsrequired.constraints.gatekeeper.sh/ingress-must-have-tls created
```

### Verificación

```bash
# Listar todos los constraints y ver estado
kubectl get constraints

# Esperar ~60s para que la auditoría se ejecute y verificar violaciones existentes
sleep 65
kubectl get k8srequiredlabels deployments-must-have-labels -o yaml | grep -A 20 "violations"
kubectl get k8sresourcelimitsrequired containers-must-have-limits -o yaml | grep "totalViolations"
```

---

## Paso 5: Validar Enforcement con Recursos que Violan Políticas

**Objetivo:** Confirmar que Gatekeeper bloquea recursos no conformes.

### Instrucciones

1. Crear el namespace de prueba:

```bash
kubectl create namespace webapp --dry-run=client -o yaml | kubectl apply -f -
```

2. Intentar crear un Deployment sin labels obligatorios:

```bash
cat > ~/k8s-labs/lab09/tests/test-no-labels.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-labels
  namespace: webapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
          resources:
            limits:
              cpu: "100m"
              memory: "128Mi"
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-no-labels.yaml
```

3. Intentar crear un Pod con imagen de registry no permitido:

```bash
cat > ~/k8s-labs/lab09/tests/test-bad-registry.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-registry
  namespace: webapp
spec:
  containers:
    - name: nginx
      image: docker.io/nginx:latest
      resources:
        limits:
          cpu: "100m"
          memory: "128Mi"
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-bad-registry.yaml
```

4. Intentar crear un Pod privilegiado:

```bash
cat > ~/k8s-labs/lab09/tests/test-privileged.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
  namespace: webapp
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:1.25
      securityContext:
        privileged: true
      resources:
        limits:
          cpu: "100m"
          memory: "128Mi"
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-privileged.yaml
```

5. Intentar crear un Ingress sin TLS:

```bash
cat > ~/k8s-labs/lab09/tests/test-ingress-no-tls.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-no-tls
  namespace: webapp
spec:
  rules:
    - host: test.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: test-svc
                port:
                  number: 80
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-ingress-no-tls.yaml
```

### Salida Esperada

Cada comando `kubectl apply` debe fallar con un mensaje similar a:

```
Error from server (Forbidden): error when creating "test-no-labels.yaml": admission webhook
"validation.gatekeeper.sh" denied the request: [deployments-must-have-labels] El recurso
'test-no-labels' debe tener las labels: {"app", "env", "team", "version"}. Faltan: {"env", "team", "version"}
```

```
Error from server (Forbidden): ... [only-approved-registries] La imagen 'docker.io/nginx:latest'
del contenedor 'nginx' no proviene de un registry permitido.
```

```
Error from server (Forbidden): ... [no-privileged-containers] El contenedor 'nginx' no puede
ejecutarse en modo privilegiado.
```

```
Error from server (Forbidden): ... [ingress-must-have-tls] El Ingress 'test-no-tls' debe
configurar TLS.
```

### Verificación

```bash
# Confirmar que ningún recurso de prueba fue creado
kubectl get pods -n webapp 2>/dev/null | grep test
kubectl get deployments -n webapp 2>/dev/null | grep test-no-labels
kubectl get ingress -n webapp 2>/dev/null | grep test-no-tls
# Todos deben devolver vacío o "No resources found"
```

---

## Paso 6: Instalar Kyverno 1.12.5

**Objetivo:** Desplegar Kyverno como motor de políticas complementario para mutación y generación.

### Instrucciones

1. Instalar Kyverno con Helm:

```bash
helm install kyverno kyverno/kyverno \
  --version 3.2.5 \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait --timeout 180s
```

> **Nota:** El chart Helm versión 3.2.5 despliega Kyverno engine 1.12.5.

2. Verificar la instalación:

```bash
kubectl get pods -n kyverno
kubectl get crd | grep kyverno
```

### Salida Esperada

```
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-xxxxxxxxx-xxxxx     1/1     Running   0          45s
kyverno-background-controller-xxxxxxxxx-xxxxx    1/1     Running   0          45s
kyverno-cleanup-controller-xxxxxxxxx-xxxxx       1/1     Running   0          45s
kyverno-reports-controller-xxxxxxxxx-xxxxx       1/1     Running   0          45s
```

### Verificación

```bash
# Verificar webhooks de Kyverno
kubectl get mutatingwebhookconfigurations | grep kyverno
kubectl get validatingwebhookconfigurations | grep kyverno
```

---

## Paso 7: Crear ClusterPolicies de Kyverno

**Objetivo:** Implementar políticas de mutación, validación y generación con Kyverno.

### Instrucciones

1. Crear ClusterPolicy de mutación — inyectar label `env=production` en namespace `webapp`:

```bash
cat > ~/k8s-labs/lab09/kyverno/mutate-inject-labels.yaml << 'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-env-label
spec:
  rules:
    - name: add-env-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - webapp
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              env: production
    - name: add-last-applied-annotation
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - Pod
              namespaces:
                - webapp
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              last-applied-by: "kyverno-policy-engine"
EOF

kubectl apply -f ~/k8s-labs/lab09/kyverno/mutate-inject-labels.yaml
```

2. Crear ClusterPolicy de validación — prohibir tag `latest`:

```bash
cat > ~/k8s-labs/lab09/kyverno/validate-no-latest.yaml << 'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: validate-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - webapp
      validate:
        message: "La imagen no puede usar el tag 'latest'. Use un tag específico."
        pattern:
          spec:
            containers:
              - image: "!*:latest & !*:latest*"
    - name: validate-initcontainer-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - webapp
      validate:
        message: "Los initContainers no pueden usar el tag 'latest'."
        pattern:
          spec:
            =(initContainers):
              - image: "!*:latest & !*:latest*"
EOF

kubectl apply -f ~/k8s-labs/lab09/kyverno/validate-no-latest.yaml
```

3. Crear ClusterPolicy de generación — crear NetworkPolicy default-deny al crear un namespace:

```bash
cat > ~/k8s-labs/lab09/kyverno/generate-default-deny.yaml << 'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-deny-netpol
spec:
  rules:
    - name: create-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kube-public
                - kube-node-lease
                - gatekeeper-system
                - kyverno
                - monitoring
                - ingress-nginx
                - cert-manager
                - local-path-storage
                - calico-system
                - calico-apiserver
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-all
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
EOF

kubectl apply -f ~/k8s-labs/lab09/kyverno/generate-default-deny.yaml
```

### Salida Esperada

```
clusterpolicy.kyverno.io/inject-env-label created
clusterpolicy.kyverno.io/disallow-latest-tag created
clusterpolicy.kyverno.io/generate-default-deny-netpol created
```

### Verificación

```bash
# Verificar que las políticas están activas
kubectl get clusterpolicies
# Debe mostrar 3 políticas con READY=True

# Probar la generación: crear un namespace de prueba
kubectl create namespace test-generation
sleep 5
kubectl get networkpolicy -n test-generation
# Debe mostrar: default-deny-all

# Limpiar namespace de prueba
kubectl delete namespace test-generation
```

---

## Paso 8: Validar Políticas de Kyverno

**Objetivo:** Confirmar que la mutación y validación de Kyverno funcionan correctamente.

### Instrucciones

1. Probar que la mutación inyecta labels:

```bash
cat > ~/k8s-labs/lab09/tests/test-kyverno-mutation.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-mutation
  namespace: webapp
  labels:
    app: test-mutation
    version: "v1.0"
    team: platform
    env: staging
spec:
  containers:
    - name: busybox
      image: localhost:5000/busybox:1.36
      command: ["sleep", "3600"]
      resources:
        limits:
          cpu: "50m"
          memory: "64Mi"
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-kyverno-mutation.yaml
```

2. Verificar que el label fue mutado:

```bash
kubectl get pod test-mutation -n webapp -o jsonpath='{.metadata.labels.env}'
# Debe mostrar: production (mutado de "staging" a "production")

kubectl get pod test-mutation -n webapp -o jsonpath='{.metadata.annotations.last-applied-by}'
# Debe mostrar: kyverno-policy-engine
```

3. Probar que la validación rechaza tag `latest`:

```bash
cat > ~/k8s-labs/lab09/tests/test-kyverno-latest.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-latest
  namespace: webapp
  labels:
    app: test-latest
    version: "v1.0"
    team: platform
    env: production
spec:
  containers:
    - name: nginx
      image: localhost:5000/nginx:latest
      resources:
        limits:
          cpu: "100m"
          memory: "128Mi"
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-kyverno-latest.yaml
```

### Salida Esperada

Para el test de tag `latest`:
```
Error from server: error when creating "test-kyverno-latest.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:
resource Pod/webapp/test-latest was blocked due to the following policies:
disallow-latest-tag:
  validate-image-tag: "La imagen no puede usar el tag 'latest'. Use un tag específico."
```

### Verificación

```bash
# Limpiar pod de prueba de mutación
kubectl delete pod test-mutation -n webapp

# Verificar PolicyReports generados
kubectl get policyreport -n webapp 2>/dev/null || kubectl get clusterpolicyreport
```

---

## Paso 9: Configurar Auditoría y Métricas de Compliance

**Objetivo:** Habilitar reportes de violaciones y exportar métricas a Prometheus.

### Instrucciones

1. Verificar que la auditoría de Gatekeeper está reportando violaciones:

```bash
# Ver violaciones actuales de todas las constraints
echo "=== Violaciones por Constraint ==="
for constraint in $(kubectl get constraints -o name); do
  echo "--- $constraint ---"
  kubectl get $constraint -o jsonpath='{.status.totalViolations}' 2>/dev/null
  echo ""
done
```

2. Crear un ServiceMonitor para que Prometheus scrape las métricas de Gatekeeper:

```bash
cat > ~/k8s-labs/lab09/metrics/gatekeeper-servicemonitor.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: gatekeeper-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - gatekeeper-system
  selector:
    matchLabels:
      app.kubernetes.io/name: gatekeeper
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
EOF

kubectl apply -f ~/k8s-labs/lab09/metrics/gatekeeper-servicemonitor.yaml
```

3. Crear un ServiceMonitor para Kyverno:

```bash
cat > ~/k8s-labs/lab09/metrics/kyverno-servicemonitor.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
  endpoints:
    - port: metrics-port
      interval: 30s
      path: /metrics
EOF

kubectl apply -f ~/k8s-labs/lab09/metrics/kyverno-servicemonitor.yaml
```

4. Crear PrometheusRule con alertas de compliance:

```bash
cat > ~/k8s-labs/lab09/metrics/compliance-alerts.yaml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gatekeeper-compliance-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gatekeeper.compliance
      interval: 60s
      rules:
        - alert: GatekeeperHighViolationCount
          expr: |
            sum(gatekeeper_violations) > 10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Alto número de violaciones de Gatekeeper"
            description: "Se detectaron más de 10 violaciones de políticas Gatekeeper en el clúster."
        - alert: GatekeeperAuditNotRunning
          expr: |
            time() - gatekeeper_audit_last_run_end_time > 300
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "La auditoría de Gatekeeper no se ha ejecutado en 5 minutos"
            description: "El controlador de auditoría de Gatekeeper puede estar fallando."
        - alert: KyvernoPolicyViolations
          expr: |
            sum(kyverno_policy_results_total{rule_result="fail"}) > 5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Violaciones de políticas Kyverno detectadas"
            description: "Se han registrado más de 5 violaciones de políticas Kyverno."
EOF

kubectl apply -f ~/k8s-labs/lab09/metrics/compliance-alerts.yaml
```

5. Crear un script de reporte de compliance:

```bash
cat > ~/k8s-labs/lab09/metrics/compliance-report.sh << 'SCRIPT'
#!/bin/bash
echo "=========================================="
echo "  REPORTE DE COMPLIANCE - $(date)"
echo "=========================================="
echo ""

echo "--- GATEKEEPER CONSTRAINTS ---"
echo ""
printf "%-45s %-15s %-10s\n" "CONSTRAINT" "ENFORCEMENT" "VIOLATIONS"
printf "%-45s %-15s %-10s\n" "---------" "-----------" "----------"

for ct in $(kubectl get constraints -o name 2>/dev/null); do
  name=$(echo $ct | cut -d/ -f2)
  enforcement=$(kubectl get $ct -o jsonpath='{.spec.enforcementAction}' 2>/dev/null)
  violations=$(kubectl get $ct -o jsonpath='{.status.totalViolations}' 2>/dev/null)
  printf "%-45s %-15s %-10s\n" "$name" "${enforcement:-deny}" "${violations:-0}"
done

echo ""
echo "--- KYVERNO POLICIES ---"
echo ""
kubectl get clusterpolicies -o custom-columns="NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.ready" 2>/dev/null

echo ""
echo "--- RESUMEN ---"
total_violations=$(kubectl get constraints -o jsonpath='{range .items[*]}{.status.totalViolations}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "Total violaciones Gatekeeper: $total_violations"

if [ "$total_violations" -gt 0 ]; then
  echo "⚠️  ESTADO: NO CONFORME - Se requiere remediación"
else
  echo "✅ ESTADO: CONFORME - Sin violaciones detectadas"
fi
echo ""
echo "=========================================="
SCRIPT

chmod +x ~/k8s-labs/lab09/metrics/compliance-report.sh
```

6. Ejecutar el reporte:

```bash
~/k8s-labs/lab09/metrics/compliance-report.sh
```

### Salida Esperada

```
==========================================
  REPORTE DE COMPLIANCE - [fecha actual]
==========================================

--- GATEKEEPER CONSTRAINTS ---

CONSTRAINT                                    ENFORCEMENT     VIOLATIONS
---------                                     -----------     ----------
deployments-must-have-labels                  deny            0
only-approved-registries                      deny            0
no-privileged-containers                      deny            0
containers-must-have-limits                   warn            X
ingress-must-have-tls                         deny            0

--- KYVERNO POLICIES ---

NAME                            ACTION    READY
inject-env-label                          true
disallow-latest-tag             Enforce   true
generate-default-deny-netpol              true

--- RESUMEN ---
Total violaciones Gatekeeper: X
...
```

### Verificación

```bash
# Verificar que Prometheus está scrapeando métricas de Gatekeeper
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 3
curl -s "http://localhost:9090/api/v1/query?query=gatekeeper_violations" | python3 -m json.tool | head -20
kill %1 2>/dev/null
```

---

## Paso 10: Desplegar un Recurso Conforme

**Objetivo:** Confirmar que un recurso que cumple todas las políticas se despliega correctamente.

### Instrucciones

1. Crear un Deployment completamente conforme:

```bash
cat > ~/k8s-labs/lab09/tests/test-compliant-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: compliant-app
  namespace: webapp
  labels:
    app: compliant-app
    version: "v1.0.0"
    team: platform
    env: production
spec:
  replicas: 1
  selector:
    matchLabels:
      app: compliant-app
  template:
    metadata:
      labels:
        app: compliant-app
        version: "v1.0.0"
        team: platform
        env: production
    spec:
      containers:
        - name: nginx
          image: localhost:5000/nginx:1.25
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
          securityContext:
            privileged: false
            runAsNonRoot: true
            runAsUser: 1000
EOF

kubectl apply -f ~/k8s-labs/lab09/tests/test-compliant-deployment.yaml
```

2. Verificar que se creó correctamente:

```bash
kubectl get deployment compliant-app -n webapp
kubectl get pods -n webapp -l app=compliant-app
```

3. Verificar que Kyverno mutó el Pod:

```bash
kubectl get pods -n webapp -l app=compliant-app -o jsonpath='{.items[0].metadata.annotations.last-applied-by}'
echo ""
# Debe mostrar: kyverno-policy-engine
```

### Salida Esperada

```
deployment.apps/compliant-app created

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
compliant-app                    1/1     1            1           10s
```

### Verificación

```bash
# Ejecutar reporte final de compliance
~/k8s-labs/lab09/metrics/compliance-report.sh

# Limpiar deployment de prueba
kubectl delete deployment compliant-app -n webapp
```

---

## Validación y Testing

Ejecuta la siguiente batería de validaciones para confirmar que todo el lab funciona correctamente:

```bash
echo "=== VALIDACIÓN COMPLETA DEL LAB 09 ==="
echo ""

# 1. Gatekeeper operativo
echo "1. Gatekeeper pods:"
kubectl get pods -n gatekeeper-system --no-headers | wc -l
echo "   (Esperado: 2 pods)"

# 2. ConstraintTemplates creadas
echo "2. ConstraintTemplates:"
kubectl get constrainttemplates --no-headers | wc -l
echo "   (Esperado: 5)"

# 3. Constraints activos
echo "3. Constraints:"
kubectl get constraints --no-headers | wc -l
echo "   (Esperado: 5)"

# 4. Kyverno operativo
echo "4. Kyverno pods:"
kubectl get pods -n kyverno --no-headers | wc -l
echo "   (Esperado: 4 pods)"

# 5. ClusterPolicies
echo "5. ClusterPolicies Kyverno:"
kubectl get clusterpolicies --no-headers | wc -l
echo "   (Esperado: 3)"

# 6. Enforcement test - debe fallar
echo "6. Test enforcement (debe fallar):"
kubectl run test-enforcement --image=docker.io/nginx:latest -n webapp --dry-run=server 2>&1 | grep -c "denied\|blocked"
echo "   (Esperado: 1 - indica rechazo)"

# 7. ServiceMonitors
echo "7. ServiceMonitors de compliance:"
kubectl get servicemonitors -n monitoring | grep -c "gatekeeper\|kyverno"
echo "   (Esperado: 2)"

# 8. PrometheusRules
echo "8. PrometheusRules:"
kubectl get prometheusrules -n monitoring | grep -c "compliance"
echo "   (Esperado: 1)"

echo ""
echo "=== VALIDACIÓN COMPLETADA ==="
```

---

## Resolución de Problemas

### Problema 1: ConstraintTemplate no genera el CRD correspondiente

**Síntomas:** Después de aplicar una ConstraintTemplate, el CRD no aparece en `kubectl get crd | grep constraints.gatekeeper.sh` y al intentar crear el Constraint se obtiene el error `no matches for kind "K8sXxx"`.

**Causa:** Error de sintaxis en el código Rego dentro de la ConstraintTemplate. Gatekeeper no puede compilar la política y no genera el CRD. Esto es especialmente común con errores de indentación en bloques Rego embebidos en YAML.

**Solución:**

```bash
# Verificar el estado de la ConstraintTemplate
kubectl get constrainttemplate k8srequiredlabels -o yaml | grep -A 10 "status:"

# Buscar errores específicos
kubectl describe constrainttemplate k8srequiredlabels | grep -A 5 "Error"

# Validar el Rego localmente antes de aplicar
opa check ~/k8s-labs/lab09/tests/required_labels.rego

# Si hay errores, corregir y reaplicar
kubectl delete constrainttemplate k8srequiredlabels
kubectl apply -f ~/k8s-labs/lab09/gatekeeper/ct-required-labels.yaml

# Verificar logs del controller
kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=50
```

### Problema 2: Kyverno no muta Pods — el label/annotation no aparece

**Síntomas:** Se crea un Pod en el namespace `webapp` pero no tiene el label `env: production` ni la annotation `last-applied-by`. La ClusterPolicy aparece como `Ready=True`.

**Causa:** El MutatingWebhookConfiguration de Kyverno puede no estar interceptando el recurso debido a un conflicto de orden con otros webhooks o porque el Pod se crea indirectamente (vía Deployment/ReplicaSet) y la política solo matchea Pods directos. También puede ocurrir si el namespace tiene la label `kubernetes.io/metadata.name` excluida en la configuración de Kyverno.

**Solución:**

```bash
# Verificar que el webhook de Kyverno está activo
kubectl get mutatingwebhookconfigurations | grep kyverno

# Verificar los eventos de la política
kubectl describe clusterpolicy inject-env-label | grep -A 10 "Events"

# Verificar si hay exclusiones de namespace
kubectl get mutatingwebhookconfigurations kyverno-resource-mutating-webhook-cfg -o yaml | grep -A 5 "namespaceSelector"

# Probar creando un Pod directamente (no vía Deployment)
kubectl run test-direct --image=localhost:5000/busybox:1.36 -n webapp \
  --labels="app=test,version=v1,team=dev,env=staging" \
  --overrides='{"spec":{"containers":[{"name":"test","image":"localhost:5000/busybox:1.36","command":["sleep","10"],"resources":{"limits":{"cpu":"50m","memory":"64Mi"}}}]}}'

# Verificar mutación
kubectl get pod test-direct -n webapp -o jsonpath='{.metadata.labels.env}'
kubectl delete pod test-direct -n webapp

# Si persiste, reiniciar el admission controller
kubectl rollout restart deployment kyverno-admission-controller -n kyverno
```

---

## Limpieza

> **Importante:** Las políticas de este lab deben permanecer activas para el Lab 10. Solo ejecuta la limpieza de recursos de prueba.

```bash
# Eliminar recursos de prueba (NO eliminar políticas)
kubectl delete pod test-mutation -n webapp --ignore-not-found
kubectl delete deployment compliant-app -n webapp --ignore-not-found

# Eliminar archivos de test que ya no se necesitan
rm -f ~/k8s-labs/lab09/tests/test-*.yaml

# Verificar que las políticas siguen activas
echo "Constraints activos:"
kubectl get constraints --no-headers | wc -l
echo "ClusterPolicies activas:"
kubectl get clusterpolicies --no-headers | wc -l
```

Si necesitas eliminar todo el lab (solo si no continuarás al Lab 10):

```bash
# SOLO SI NO CONTINÚAS AL LAB 10
# helm uninstall kyverno -n kyverno
# helm uninstall gatekeeper -n gatekeeper-system
# kubectl delete namespace kyverno gatekeeper-system
# kubectl delete crd -l gatekeeper.sh/system=yes
# kubectl delete crd -l app.kubernetes.io/managed-by=kyverno
```

---

## Resumen

En este laboratorio has implementado una capa completa de governance para Kubernetes:

| Componente | Resultado |
|-----------|-----------|
| OPA Gatekeeper 3.16.3 | Instalado con auditoría cada 60s y métricas Prometheus |
| ConstraintTemplates | 5 plantillas Rego: labels, registries, privileged, limits, TLS |
| Constraints | 5 instancias: 4 en modo `deny`, 1 en modo `warn` |
| Kyverno 1.12.5 | Instalado con 3 ClusterPolicies activas |
| Mutación | Labels y annotations inyectados automáticamente |
| Generación | NetworkPolicy default-deny al crear namespaces |
| Observabilidad | ServiceMonitors + PrometheusRules con alertas de compliance |

### Conceptos Clave Aplicados

- **Separación de concerns:** Gatekeeper para validación estricta con Rego; Kyverno para mutación y generación en YAML
- **Enforcement gradual:** Políticas críticas en `deny`, informativas en `warn`
- **Auditoría continua:** Gatekeeper evalúa recursos existentes cada 60 segundos
- **Compliance as Code:** Políticas versionables, testeables con OPA CLI y monitorizables

### Recursos Adicionales

- [Gatekeeper Policy Library](https://github.com/open-policy-agent/gatekeeper-library)
- [Kyverno Policy Catalog](https://kyverno.io/policies/)
- [OPA Rego Playground](https://play.openpolicyagent.org/)
- [Documentación de Gatekeeper Audit](https://open-policy-agent.github.io/gatekeeper/website/docs/audit/)
