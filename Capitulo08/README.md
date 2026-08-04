# Aplicar Hardening, Políticas y Auditoría en Clúster

## Metadatos

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Aplicar |
| **Clúster** | `lab-calico` (contexto: `kind-lab-calico`) |
| **Directorio de trabajo** | `~/k8s-labs/lab08/` |

## Descripción General

Este laboratorio implementa una capa completa de seguridad sobre el clúster `lab-calico` existente. Se configurarán cuatro perfiles RBAC con principio de mínimo privilegio, Network Policies de aislamiento en todos los namespaces activos, Sealed Secrets para gestión segura de credenciales, auditoría del API Server, escaneo de vulnerabilidades con Trivy, detección en runtime con Falco y benchmark CIS con kube-bench. Al finalizar, el clúster tendrá controles de seguridad defensivos en profundidad aplicados y verificables.

## Objetivos de Aprendizaje

- [ ] Implementar RBAC granular con Roles, ClusterRoles y RoleBindings para 4 perfiles de usuario siguiendo mínimo privilegio
- [ ] Configurar Network Policies default-deny con allow-lists específicas en 5 namespaces del clúster
- [ ] Desplegar Sealed Secrets y migrar credenciales sensibles a formato encriptado apto para Git
- [ ] Configurar audit logging del API Server con política multinivel y verificar la captura de eventos
- [ ] Ejecutar escaneo de seguridad con Trivy, Falco y kube-bench documentando hallazgos

## Prerrequisitos

### Conocimientos Requeridos

- Comprensión de RBAC (Role, ClusterRole, RoleBinding, ClusterRoleBinding)
- Familiaridad con NetworkPolicy de Kubernetes
- Experiencia con Helm y gestión de charts
- Comprensión de SecurityContext en pods

### Acceso y Herramientas

| Herramienta | Versión | Verificación |
|-------------|---------|--------------|
| kubectl | 1.30.2 | `kubectl version --client` |
| Helm | 3.15.2 | `helm version` |
| kubeseal | 0.27.1 | `kubeseal --version` |
| Trivy | 0.53.0 | `trivy --version` |
| kustomize | 5.4.2 | `kustomize version` |
| kind | 0.23.0 | `kind version` |

### Verificación del Entorno Previo

```bash
# Verificar que el clúster lab-calico está activo
kubectl cluster-info --context kind-lab-calico

# Verificar namespaces de labs anteriores
kubectl get ns webapp logging monitoring ingress-nginx webapp-operator-system 2>/dev/null
```

## Entorno del Laboratorio

### Preparación del Directorio

```bash
mkdir -p ~/k8s-labs/lab08/{rbac,network-policies,sealed-secrets,audit,scanning,security-contexts}
cd ~/k8s-labs/lab08/
```

### Contexto del Clúster

```bash
kubectl config use-context kind-lab-calico
```

---

## Paso 1: Configurar RBAC Granular — Perfiles de Usuario

**Objetivo:** Crear 4 perfiles de acceso RBAC con principio de mínimo privilegio: `dev-user`, `ops-user`, `security-auditor` y `ci-serviceaccount`.

### Instrucciones

1. Crear las ServiceAccounts para simular los usuarios:

```bash
cat > ~/k8s-labs/lab08/rbac/serviceaccounts.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev-user
  namespace: webapp
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ops-user
  namespace: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: security-auditor
  namespace: kube-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-serviceaccount
  namespace: webapp
EOF

kubectl apply -f ~/k8s-labs/lab08/rbac/serviceaccounts.yaml
```

2. Crear el Role para `dev-user` (lectura en namespace webapp):

```bash
cat > ~/k8s-labs/lab08/rbac/dev-user-role.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: webapp
  name: dev-reader
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "configmaps", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-user-reader-binding
  namespace: webapp
subjects:
  - kind: ServiceAccount
    name: dev-user
    namespace: webapp
roleRef:
  kind: Role
  name: dev-reader
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f ~/k8s-labs/lab08/rbac/dev-user-role.yaml
```

3. Crear el ClusterRole y bindings para `ops-user` (acceso completo en namespaces operacionales):

```bash
cat > ~/k8s-labs/lab08/rbac/ops-user-role.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ops-full-access
rules:
  - apiGroups: ["", "apps", "batch", "extensions"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ops-user-monitoring-binding
  namespace: monitoring
subjects:
  - kind: ServiceAccount
    name: ops-user
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: ops-full-access
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ops-user-logging-binding
  namespace: logging
subjects:
  - kind: ServiceAccount
    name: ops-user
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: ops-full-access
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ops-user-ingress-binding
  namespace: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ops-user
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: ops-full-access
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f ~/k8s-labs/lab08/rbac/ops-user-role.yaml
```

4. Crear el ClusterRole para `security-auditor` (lectura global):

```bash
cat > ~/k8s-labs/lab08/rbac/security-auditor-role.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: security-auditor-readonly
rules:
  - apiGroups: ["", "apps", "batch", "rbac.authorization.k8s.io", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["policy"]
    resources: ["podsecuritypolicies", "poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  # Explícitamente NO incluye secrets/list para evitar exposición masiva
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    # Nota: get sin list requiere conocer el nombre exacto del secret
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: security-auditor-binding
subjects:
  - kind: ServiceAccount
    name: security-auditor
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: security-auditor-readonly
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f ~/k8s-labs/lab08/rbac/security-auditor-role.yaml
```

5. Crear el Role para `ci-serviceaccount` (permisos específicos para pipeline):

```bash
cat > ~/k8s-labs/lab08/rbac/ci-serviceaccount-role.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: webapp
  name: ci-deployer
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer-binding
  namespace: webapp
subjects:
  - kind: ServiceAccount
    name: ci-serviceaccount
    namespace: webapp
roleRef:
  kind: Role
  name: ci-deployer
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f ~/k8s-labs/lab08/rbac/ci-serviceaccount-role.yaml
```

### Salida Esperada

```
serviceaccount/dev-user created
serviceaccount/ops-user created
serviceaccount/security-auditor created
serviceaccount/ci-serviceaccount created
role.rbac.authorization.k8s.io/dev-reader created
rolebinding.rbac.authorization.k8s.io/dev-user-reader-binding created
clusterrole.rbac.authorization.k8s.io/ops-full-access created
rolebinding.rbac.authorization.k8s.io/ops-user-monitoring-binding created
...
```

### Verificación

```bash
# dev-user puede listar pods en webapp
kubectl auth can-i list pods --namespace=webapp \
  --as=system:serviceaccount:webapp:dev-user
# Esperado: yes

# dev-user NO puede crear deployments en webapp
kubectl auth can-i create deployments --namespace=webapp \
  --as=system:serviceaccount:webapp:dev-user
# Esperado: no

# dev-user NO puede listar pods en monitoring
kubectl auth can-i list pods --namespace=monitoring \
  --as=system:serviceaccount:webapp:dev-user
# Esperado: no

# ops-user puede crear pods en monitoring
kubectl auth can-i create pods --namespace=monitoring \
  --as=system:serviceaccount:monitoring:ops-user
# Esperado: yes

# security-auditor puede listar rolebindings cluster-wide
kubectl auth can-i list rolebindings --all-namespaces \
  --as=system:serviceaccount:kube-system:security-auditor
# Esperado: yes

# ci-serviceaccount puede actualizar deployments en webapp
kubectl auth can-i update deployments --namespace=webapp \
  --as=system:serviceaccount:webapp:ci-serviceaccount
# Esperado: yes

# ci-serviceaccount NO puede eliminar namespaces
kubectl auth can-i delete namespaces \
  --as=system:serviceaccount:webapp:ci-serviceaccount
# Esperado: no
```

---

## Paso 2: Configurar Network Policies — Default-Deny con Allow-Lists

**Objetivo:** Aplicar aislamiento de red completo en los namespaces `webapp`, `logging`, `monitoring`, `ingress-nginx` y `webapp-operator-system`, permitiendo solo el tráfico necesario.

### Instrucciones

1. Crear la política default-deny para todos los namespaces objetivo:

```bash
cat > ~/k8s-labs/lab08/network-policies/default-deny.yaml << 'EOF'
# Default deny ingress y egress para webapp
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: webapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: logging
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ingress-nginx
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: webapp-operator-system
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF

kubectl apply -f ~/k8s-labs/lab08/network-policies/default-deny.yaml
```

2. Crear allow-lists para el namespace `webapp`:

```bash
cat > ~/k8s-labs/lab08/network-policies/webapp-allow.yaml << 'EOF'
# Permitir ingress desde ingress-nginx
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-nginx
  namespace: webapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
# Permitir ingress desde monitoring (scraping Prometheus)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-monitoring
  namespace: webapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8080
---
# Permitir egress a DNS y a logging
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-dns-logging
  namespace: webapp
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: logging
      ports:
        - protocol: TCP
          port: 9200
EOF

kubectl apply -f ~/k8s-labs/lab08/network-policies/webapp-allow.yaml
```

3. Crear allow-lists para el namespace `monitoring`:

```bash
cat > ~/k8s-labs/lab08/network-policies/monitoring-allow.yaml << 'EOF'
# Permitir ingress desde ingress-nginx (Grafana UI)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-from-nginx
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
# Permitir egress a todos los namespaces (scraping) y DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-scraping
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 9090
        - protocol: TCP
          port: 9100
        - protocol: TCP
          port: 3000
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Permitir comunicación interna entre pods de monitoring
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internal
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF

kubectl apply -f ~/k8s-labs/lab08/network-policies/monitoring-allow.yaml
```

4. Crear allow-lists para `ingress-nginx`:

```bash
cat > ~/k8s-labs/lab08/network-policies/ingress-nginx-allow.yaml << 'EOF'
# Permitir ingress externo (tráfico de clientes)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-ingress
  namespace: ingress-nginx
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
---
# Permitir egress hacia webapp, monitoring, logging y DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-backends
  namespace: ingress-nginx
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: webapp
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: logging
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

kubectl apply -f ~/k8s-labs/lab08/network-policies/ingress-nginx-allow.yaml
```

5. Crear allow-lists para `webapp-operator-system`:

```bash
cat > ~/k8s-labs/lab08/network-policies/operator-allow.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-apiserver-dns
  namespace: webapp-operator-system
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 6443
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-webhook
  namespace: webapp-operator-system
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: 9443
EOF

kubectl apply -f ~/k8s-labs/lab08/network-policies/operator-allow.yaml
```

### Verificación

```bash
# Listar todas las NetworkPolicies creadas
kubectl get networkpolicies -A | grep -E "webapp|logging|monitoring|ingress-nginx|operator"

# Verificar que default-deny existe en cada namespace
for ns in webapp logging monitoring ingress-nginx webapp-operator-system; do
  echo "--- $ns ---"
  kubectl get networkpolicy default-deny-all -n $ns -o name 2>/dev/null || echo "MISSING"
done
```

---

## Paso 3: Desplegar Sealed Secrets y Migrar Credenciales

**Objetivo:** Instalar el controlador Sealed Secrets y migrar el Secret de Elasticsearch a un SealedSecret encriptado apto para almacenamiento en Git.

### Instrucciones

1. Instalar el controlador Sealed Secrets:

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version 2.16.1 \
  --set-string fullnameOverride=sealed-secrets-controller \
  --wait
```

2. Verificar que el controlador está corriendo:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets
kubectl -n kube-system get svc sealed-secrets-controller
```

3. Crear el Secret original de Elasticsearch (si no existe):

```bash
cat > ~/k8s-labs/lab08/sealed-secrets/es-credentials-secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: elasticsearch-credentials
  namespace: logging
type: Opaque
stringData:
  username: elastic
  password: ElasticK8s2024!
EOF
```

4. Encriptar el Secret con kubeseal:

```bash
kubeseal --format yaml \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  < ~/k8s-labs/lab08/sealed-secrets/es-credentials-secret.yaml \
  > ~/k8s-labs/lab08/sealed-secrets/es-credentials-sealed.yaml

# Ver el resultado encriptado
cat ~/k8s-labs/lab08/sealed-secrets/es-credentials-sealed.yaml
```

5. Aplicar el SealedSecret (reemplaza el Secret original):

```bash
# Eliminar el Secret original si existe
kubectl delete secret elasticsearch-credentials -n logging --ignore-not-found

# Aplicar el SealedSecret
kubectl apply -f ~/k8s-labs/lab08/sealed-secrets/es-credentials-sealed.yaml
```

6. Verificar que el controlador descifró y creó el Secret:

```bash
kubectl get secret elasticsearch-credentials -n logging -o jsonpath='{.data.username}' | base64 -d
echo
kubectl get secret elasticsearch-credentials -n logging -o jsonpath='{.data.password}' | base64 -d
echo
```

### Salida Esperada

```
elastic
ElasticK8s2024!
```

### Verificación

```bash
# El SealedSecret debe existir como recurso
kubectl get sealedsecret elasticsearch-credentials -n logging

# El archivo sellado NO contiene la contraseña en texto claro
grep -c "ElasticK8s2024" ~/k8s-labs/lab08/sealed-secrets/es-credentials-sealed.yaml
# Esperado: 0

# Eliminar el archivo con el secreto en texto claro (buena práctica)
rm -f ~/k8s-labs/lab08/sealed-secrets/es-credentials-secret.yaml
```

---

## Paso 4: Configurar Auditoría del API Server

**Objetivo:** Crear una política de audit logging multinivel y configurar el API Server de kind para capturar eventos de seguridad.

### Instrucciones

1. Crear la política de auditoría:

```bash
cat > ~/k8s-labs/lab08/audit/audit-policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # No registrar health checks ni watch de system components
  - level: None
    users: ["system:kube-proxy", "system:kube-scheduler", "system:kube-controller-manager"]
    verbs: ["get", "watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "namespaces"]

  # No registrar health checks del kubelet
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"

  # RequestResponse para operaciones sobre Secrets
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]
    verbs: ["create", "update", "delete", "patch"]

  # RequestResponse para operaciones RBAC
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs: ["create", "update", "delete", "patch", "bind", "escalate"]

  # Request para lectura de Secrets (detectar accesos)
  - level: Request
    resources:
      - group: ""
        resources: ["secrets"]
    verbs: ["get", "list", "watch"]

  # Metadata para recursos estándar
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods", "services", "configmaps", "namespaces"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]

  # Metadata catch-all para todo lo demás
  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF
```

2. Recrear el clúster kind con auditoría habilitada. Primero, crear la configuración:

```bash
cat > ~/k8s-labs/lab08/audit/kind-config-audit.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab-calico
nodes:
  - role: control-plane
    image: kindest/node:v1.30.2
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-log-path: /var/log/kubernetes/audit.log
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
            audit-log-maxage: "7"
            audit-log-maxbackup: "3"
            audit-log-maxsize: "100"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
              pathType: File
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
  - role: worker
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
EOF
```

3. Aplicar la política de auditoría al nodo control-plane existente (sin recrear el clúster):

```bash
# Copiar la política de auditoría al nodo control-plane
docker cp ~/k8s-labs/lab08/audit/audit-policy.yaml \
  lab-calico-control-plane:/etc/kubernetes/audit-policy.yaml

# Crear directorio de logs
docker exec lab-calico-control-plane mkdir -p /var/log/kubernetes

# Modificar el manifiesto estático del API Server para habilitar auditoría
docker exec lab-calico-control-plane bash -c '
cat /etc/kubernetes/manifests/kube-apiserver.yaml | \
  sed "/- --tls-private-key-file/a\\    - --audit-log-path=/var/log/kubernetes/audit.log\n    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml\n    - --audit-log-maxage=7\n    - --audit-log-maxbackup=3\n    - --audit-log-maxsize=100" | \
  sed "/volumeMounts:/a\\    - mountPath: /etc/kubernetes/audit-policy.yaml\n      name: audit-policy\n      readOnly: true\n    - mountPath: /var/log/kubernetes\n      name: audit-logs" | \
  sed "/volumes:/a\\  - hostPath:\n      path: /etc/kubernetes/audit-policy.yaml\n      type: File\n    name: audit-policy\n  - hostPath:\n      path: /var/log/kubernetes\n      type: DirectoryOrCreate\n    name: audit-logs" \
  > /tmp/kube-apiserver.yaml && \
  cp /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
'
```

> **Nota:** Si la modificación in-place del manifiesto estático resulta compleja, use el método alternativo con `kubectl` patch o recree el clúster con la configuración del paso 2.

4. Método alternativo más fiable — parchear directamente:

```bash
# Extraer el manifiesto actual
docker cp lab-calico-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml \
  ~/k8s-labs/lab08/audit/kube-apiserver-original.yaml

# Crear script de patch
cat > ~/k8s-labs/lab08/audit/patch-apiserver.py << 'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    manifest = yaml.safe_load(f)

# Añadir args
args = manifest['spec']['containers'][0]['command']
audit_args = [
    '--audit-log-path=/var/log/kubernetes/audit.log',
    '--audit-policy-file=/etc/kubernetes/audit-policy.yaml',
    '--audit-log-maxage=7',
    '--audit-log-maxbackup=3',
    '--audit-log-maxsize=100'
]
for a in audit_args:
    if a not in args:
        args.append(a)

# Añadir volumeMounts
vmounts = manifest['spec']['containers'][0]['volumeMounts']
vmounts.append({'mountPath': '/etc/kubernetes/audit-policy.yaml', 'name': 'audit-policy', 'readOnly': True})
vmounts.append({'mountPath': '/var/log/kubernetes', 'name': 'audit-logs'})

# Añadir volumes
vols = manifest['spec']['volumes']
vols.append({'hostPath': {'path': '/etc/kubernetes/audit-policy.yaml', 'type': 'File'}, 'name': 'audit-policy'})
vols.append({'hostPath': {'path': '/var/log/kubernetes', 'type': 'DirectoryOrCreate'}, 'name': 'audit-logs'})

with open(sys.argv[1], 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False)
PYEOF

# Ejecutar el patch
pip3 install pyyaml -q 2>/dev/null
python3 ~/k8s-labs/lab08/audit/patch-apiserver.py ~/k8s-labs/lab08/audit/kube-apiserver-original.yaml

# Copiar el manifiesto parcheado de vuelta
docker cp ~/k8s-labs/lab08/audit/kube-apiserver-original.yaml \
  lab-calico-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml
```

5. Esperar a que el API Server reinicie y verificar:

```bash
# Esperar hasta 60 segundos a que el API Server vuelva
sleep 30
kubectl wait --for=condition=Ready node/lab-calico-control-plane --timeout=60s

# Generar un evento auditable: leer un secret
kubectl get secret elasticsearch-credentials -n logging

# Verificar que se generan logs de auditoría
docker exec lab-calico-control-plane cat /var/log/kubernetes/audit.log | tail -5
```

### Salida Esperada

```json
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Request","auditID":"...","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/logging/secrets/elasticsearch-credentials",...}
```

### Verificación

```bash
# Buscar eventos de acceso a secrets en el audit log
docker exec lab-calico-control-plane grep '"secrets"' /var/log/kubernetes/audit.log | wc -l
# Esperado: al menos 1

# Buscar eventos RBAC
docker exec lab-calico-control-plane grep 'rbac.authorization.k8s.io' /var/log/kubernetes/audit.log | head -3
```

---

## Paso 5: Escaneo de Vulnerabilidades con Trivy

**Objetivo:** Ejecutar Trivy para escanear imágenes de contenedores desplegadas en el clúster e identificar vulnerabilidades.

### Instrucciones

1. Escanear las imágenes principales del clúster:

```bash
# Obtener las imágenes en uso en el namespace webapp
WEBAPP_IMAGES=$(kubectl get pods -n webapp -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u)

echo "Imágenes en webapp:"
echo "$WEBAPP_IMAGES"

# Escanear cada imagen
mkdir -p ~/k8s-labs/lab08/scanning/trivy-reports

for img in $WEBAPP_IMAGES; do
  REPORT_NAME=$(echo "$img" | tr '/:' '_')
  echo "=== Escaneando: $img ==="
  trivy image --severity HIGH,CRITICAL \
    --format table \
    --output ~/k8s-labs/lab08/scanning/trivy-reports/${REPORT_NAME}.txt \
    "$img" 2>/dev/null
  echo "Reporte guardado: ${REPORT_NAME}.txt"
done
```

2. Escanear la configuración del clúster con Trivy:

```bash
# Escaneo de configuración Kubernetes
trivy k8s --report summary \
  --namespace webapp \
  --output ~/k8s-labs/lab08/scanning/trivy-reports/k8s-config-scan.txt \
  2>/dev/null

cat ~/k8s-labs/lab08/scanning/trivy-reports/k8s-config-scan.txt
```

3. Escanear una imagen específica de infraestructura:

```bash
# Escanear la imagen de NGINX Ingress Controller
trivy image --severity HIGH,CRITICAL \
  registry.k8s.io/ingress-nginx/controller:v1.10.1 \
  2>/dev/null | tee ~/k8s-labs/lab08/scanning/trivy-reports/ingress-nginx.txt
```

### Verificación

```bash
# Verificar que se generaron reportes
ls -la ~/k8s-labs/lab08/scanning/trivy-reports/
# Debe haber al menos 2 archivos .txt
```

---

## Paso 6: Runtime Security con Falco

**Objetivo:** Desplegar Falco con reglas personalizadas para detectar actividad sospechosa en tiempo real.

### Instrucciones

1. Añadir el repositorio de Falco e instalar:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

cat > ~/k8s-labs/lab08/scanning/falco-values.yaml << 'EOF'
driver:
  kind: modern_ebpf

falco:
  rules_file:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/falco_rules.local.yaml
    - /etc/falco/rules.d

  json_output: true
  log_stderr: true
  log_syslog: false

customRules:
  custom-rules.yaml: |-
    - rule: Exec in Production Container
      desc: Detect exec into containers in webapp namespace
      condition: >
        spawned_process and container and
        k8s.ns.name = "webapp" and
        proc.pname = "runc:[2:INIT]"
      output: >
        Shell exec detected in production (user=%user.name command=%proc.cmdline
        container=%container.name namespace=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [container, shell, production]

    - rule: Write to /etc in Container
      desc: Detect writes to /etc directory inside containers
      condition: >
        open_write and container and fd.name startswith /etc/
      output: >
        Write to /etc detected (user=%user.name command=%proc.cmdline
        file=%fd.name container=%container.name namespace=%k8s.ns.name)
      priority: ERROR
      tags: [filesystem, container]

    - rule: ServiceAccount Token Access
      desc: Detect access to ServiceAccount token files
      condition: >
        open_read and container and
        fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount/
      output: >
        SA token accessed (user=%user.name command=%proc.cmdline
        file=%fd.name container=%container.name namespace=%k8s.ns.name pod=%k8s.pod.name)
      priority: NOTICE
      tags: [token, kubernetes]

tty: true
EOF

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --version 4.7.2 \
  --values ~/k8s-labs/lab08/scanning/falco-values.yaml \
  --wait --timeout 120s
```

2. Verificar que Falco está corriendo:

```bash
kubectl -n falco get pods
kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=20
```

3. Generar un evento detectable por Falco:

```bash
# Ejecutar un exec en un pod de webapp (si existe)
WEBAPP_POD=$(kubectl get pods -n webapp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WEBAPP_POD" ]; then
  kubectl exec -n webapp "$WEBAPP_POD" -- ls /etc/hostname 2>/dev/null || true
fi

# Esperar unos segundos y revisar logs de Falco
sleep 10
kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=30 | grep -i "warning\|error\|notice" | head -10
```

### Verificación

```bash
# Falco debe estar en estado Running
kubectl -n falco get pods -o wide
# Esperado: pods en estado Running

# Verificar que las reglas custom están cargadas
kubectl -n falco logs -l app.kubernetes.io/name=falco | grep -i "custom-rules" | head -3
```

---

## Paso 7: Benchmark CIS con kube-bench

**Objetivo:** Ejecutar kube-bench con perfil CIS 1.9 y documentar los hallazgos de seguridad.

### Instrucciones

1. Ejecutar kube-bench como Job en el nodo control-plane:

```bash
cat > ~/k8s-labs/lab08/scanning/kube-bench-job.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: default
spec:
  template:
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:v0.8.0
          command: ["kube-bench", "run", "--targets", "master", "--benchmark", "cis-1.9"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
  backoffLimit: 0
EOF

kubectl apply -f ~/k8s-labs/lab08/scanning/kube-bench-job.yaml
```

2. Esperar a que el Job termine y obtener resultados:

```bash
kubectl wait --for=condition=complete job/kube-bench-master --timeout=120s

# Guardar resultados
kubectl logs job/kube-bench-master > ~/k8s-labs/lab08/scanning/kube-bench-results.txt

# Ver resumen
echo "=== RESUMEN kube-bench ==="
grep -E "^==" ~/k8s-labs/lab08/scanning/kube-bench-results.txt
echo ""
echo "=== TOTALES ==="
tail -10 ~/k8s-labs/lab08/scanning/kube-bench-results.txt
```

3. Ejecutar kube-bench en un nodo worker:

```bash
cat > ~/k8s-labs/lab08/scanning/kube-bench-worker-job.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-worker
  namespace: default
spec:
  template:
    spec:
      hostPID: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:v0.8.0
          command: ["kube-bench", "run", "--targets", "node", "--benchmark", "cis-1.9"]
          volumeMounts:
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
  backoffLimit: 0
EOF

kubectl apply -f ~/k8s-labs/lab08/scanning/kube-bench-worker-job.yaml
kubectl wait --for=condition=complete job/kube-bench-worker --timeout=120s
kubectl logs job/kube-bench-worker > ~/k8s-labs/lab08/scanning/kube-bench-worker-results.txt

echo "=== TOTALES WORKER ==="
tail -10 ~/k8s-labs/lab08/scanning/kube-bench-worker-results.txt
```

### Salida Esperada

```
== Summary master ==
45 checks PASS
12 checks FAIL
18 checks WARN
0 checks INFO
```

### Verificación

```bash
# Los archivos de resultados deben existir y tener contenido
wc -l ~/k8s-labs/lab08/scanning/kube-bench-results.txt
# Esperado: más de 50 líneas

# Identificar los FAIL más críticos
grep "\[FAIL\]" ~/k8s-labs/lab08/scanning/kube-bench-results.txt | head -5
```

---

## Paso 8: Aplicar SecurityContext con Kustomize

**Objetivo:** Crear overlays de kustomize que añadan SecurityContext restrictivo (runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation: false) a los Deployments del namespace webapp.

### Instrucciones

1. Crear la estructura de kustomize:

```bash
mkdir -p ~/k8s-labs/lab08/security-contexts/{base,overlays/hardened}
```

2. Crear el patch de SecurityContext:

```bash
cat > ~/k8s-labs/lab08/security-contexts/overlays/hardened/security-patch.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: placeholder
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: placeholder
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
EOF
```

3. Obtener los Deployments actuales del namespace webapp y crear la base:

```bash
# Exportar deployments actuales
kubectl get deployments -n webapp -o yaml > ~/k8s-labs/lab08/security-contexts/base/deployments.yaml 2>/dev/null

# Si no hay deployments en webapp, crear uno de ejemplo
if [ ! -s ~/k8s-labs/lab08/security-contexts/base/deployments.yaml ]; then
cat > ~/k8s-labs/lab08/security-contexts/base/deployments.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-demo
  namespace: webapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webapp-demo
  template:
    metadata:
      labels:
        app: webapp-demo
    spec:
      containers:
        - name: webapp
          image: nginx:1.27-alpine
          ports:
            - containerPort: 8080
EOF
fi

# Crear kustomization.yaml base
cat > ~/k8s-labs/lab08/security-contexts/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployments.yaml
EOF
```

4. Crear el overlay hardened:

```bash
cat > ~/k8s-labs/lab08/security-contexts/overlays/hardened/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - target:
      kind: Deployment
    patch: |-
      - op: add
        path: /spec/template/spec/securityContext
        value:
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
      - op: add
        path: /spec/template/spec/containers/0/securityContext
        value:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
              - ALL
EOF
```

5. Construir y aplicar el overlay:

```bash
# Previsualizar el resultado
kustomize build ~/k8s-labs/lab08/security-contexts/overlays/hardened/

# Aplicar al clúster
kustomize build ~/k8s-labs/lab08/security-contexts/overlays/hardened/ | kubectl apply -n webapp -f -
```

6. Verificar que el SecurityContext se aplicó:

```bash
kubectl get deployment -n webapp -o jsonpath='{range .items[*]}{.metadata.name}: runAsNonRoot={.spec.template.spec.securityContext.runAsNonRoot}, readOnlyRootFilesystem={.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}{end}'
```

### Salida Esperada

```
webapp-demo: runAsNonRoot=true, readOnlyRootFilesystem=true
```

### Verificación

```bash
# Verificar que allowPrivilegeEscalation es false
kubectl get deployment -n webapp -o yaml | grep -A3 "securityContext" | grep "allowPrivilegeEscalation"
# Esperado: allowPrivilegeEscalation: false

# Verificar que capabilities DROP ALL está presente
kubectl get deployment -n webapp -o yaml | grep -A5 "capabilities"
```

---

## Validación y Testing Final

Ejecutar la siguiente batería de verificaciones para confirmar que todos los controles de seguridad están operativos:

```bash
echo "============================================"
echo " VALIDACIÓN COMPLETA - Lab 08 Hardening"
echo "============================================"

echo ""
echo "1. RBAC - Perfiles de usuario"
echo "---"
echo -n "  dev-user list pods (webapp): "
kubectl auth can-i list pods -n webapp --as=system:serviceaccount:webapp:dev-user
echo -n "  dev-user create deploy (webapp): "
kubectl auth can-i create deployments -n webapp --as=system:serviceaccount:webapp:dev-user
echo -n "  ops-user create pods (monitoring): "
kubectl auth can-i create pods -n monitoring --as=system:serviceaccount:monitoring:ops-user
echo -n "  security-auditor list all (cluster): "
kubectl auth can-i list pods --all-namespaces --as=system:serviceaccount:kube-system:security-auditor
echo -n "  ci-sa update deploy (webapp): "
kubectl auth can-i update deployments -n webapp --as=system:serviceaccount:webapp:ci-serviceaccount
echo -n "  ci-sa delete ns (cluster): "
kubectl auth can-i delete namespaces --as=system:serviceaccount:webapp:ci-serviceaccount

echo ""
echo "2. Network Policies"
echo "---"
NP_COUNT=$(kubectl get networkpolicies -A --no-headers 2>/dev/null | grep -cE "webapp|logging|monitoring|ingress-nginx|operator")
echo "  NetworkPolicies creadas: $NP_COUNT (esperado: >= 10)"

echo ""
echo "3. Sealed Secrets"
echo "---"
echo -n "  Controller running: "
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets --no-headers | grep -c Running
echo -n "  SealedSecret exists: "
kubectl get sealedsecret -n logging --no-headers 2>/dev/null | wc -l

echo ""
echo "4. Audit Logging"
echo "---"
AUDIT_LINES=$(docker exec lab-calico-control-plane wc -l /var/log/kubernetes/audit.log 2>/dev/null | awk '{print $1}')
echo "  Líneas en audit.log: ${AUDIT_LINES:-0}"

echo ""
echo "5. Falco"
echo "---"
echo -n "  Falco pods running: "
kubectl -n falco get pods --no-headers 2>/dev/null | grep -c Running

echo ""
echo "6. kube-bench"
echo "---"
echo -n "  Resultados master: "
wc -l ~/k8s-labs/lab08/scanning/kube-bench-results.txt 2>/dev/null | awk '{print $1 " líneas"}'

echo ""
echo "7. SecurityContext"
echo "---"
echo -n "  Deployments con runAsNonRoot en webapp: "
kubectl get deploy -n webapp -o json | jq '[.items[] | select(.spec.template.spec.securityContext.runAsNonRoot==true)] | length'

echo ""
echo "============================================"
echo " VALIDACIÓN COMPLETA"
echo "============================================"
```

---

## Troubleshooting

### Problema 1: El API Server no reinicia después de modificar el manifiesto de auditoría

**Síntomas:**
- `kubectl` devuelve "The connection to the server was refused"
- El pod `kube-apiserver` no aparece en `docker exec lab-calico-control-plane crictl ps`

**Causa:** El manifiesto YAML del API Server tiene un error de sintaxis introducido durante la edición manual, o la ruta al archivo `audit-policy.yaml` no existe dentro del contenedor.

**Solución:**

```bash
# Verificar logs del kubelet para ver el error
docker exec lab-calico-control-plane journalctl -u kubelet --no-pager | tail -30

# Restaurar el manifiesto original
docker cp ~/k8s-labs/lab08/audit/kube-apiserver-original.yaml \
  lab-calico-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml

# Esperar a que el API Server vuelva
sleep 30
kubectl cluster-info

# Verificar que el archivo de política existe en el nodo
docker exec lab-calico-control-plane ls -la /etc/kubernetes/audit-policy.yaml

# Si no existe, copiarlo de nuevo
docker cp ~/k8s-labs/lab08/audit/audit-policy.yaml \
  lab-calico-control-plane:/etc/kubernetes/audit-policy.yaml

# Volver a intentar el patch
```

### Problema 2: Falco no inicia — error de driver eBPF

**Síntomas:**
- Los pods de Falco quedan en `CrashLoopBackOff`
- Los logs muestran: `Unable to load the driver` o `eBPF probe not found`

**Causa:** El kernel del host no soporta modern eBPF o los headers del kernel no están disponibles dentro del nodo kind (contenedor Docker).

**Solución:**

```bash
# Verificar los logs del pod Falco
kubectl -n falco logs -l app.kubernetes.io/name=falco --previous

# Cambiar el driver a 'modern_ebpf' o 'kmod' según soporte
# Actualizar values para usar el modo sin driver (userspace)
cat > /tmp/falco-fix-values.yaml << 'EOF'
driver:
  kind: modern_ebpf
  loader:
    enabled: false

falco:
  rules_file:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/rules.d
  json_output: true
EOF

# Si modern_ebpf no funciona, intentar con 'manual' (sin driver)
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --values ~/k8s-labs/lab08/scanning/falco-values.yaml \
  --set driver.kind=modern_ebpf \
  --wait --timeout 120s

# Si persiste, verificar la versión del kernel
docker exec lab-calico-control-plane uname -r
# Requiere kernel >= 5.8 para modern_ebpf
```

---

## Limpieza

Para eliminar los recursos creados en este lab sin afectar los componentes de labs anteriores:

```bash
# Eliminar Jobs de kube-bench
kubectl delete job kube-bench-master kube-bench-worker --ignore-not-found

# Eliminar Falco
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco --ignore-not-found

# Eliminar Sealed Secrets controller (opcional, mantener si se necesita)
# helm uninstall sealed-secrets -n kube-system

# Eliminar Network Policies (PRECAUCIÓN: restaura conectividad completa)
# for ns in webapp logging monitoring ingress-nginx webapp-operator-system; do
#   kubectl delete networkpolicies --all -n $ns
# done

# Nota: RBAC y SecurityContexts se mantienen como parte del hardening permanente
echo "Limpieza selectiva completada. RBAC, NetworkPolicies y SecurityContexts permanecen activos."
```

Para una limpieza completa (revertir todo):

```bash
# Eliminar todos los recursos RBAC custom
kubectl delete -f ~/k8s-labs/lab08/rbac/ --ignore-not-found
kubectl delete -f ~/k8s-labs/lab08/network-policies/ --ignore-not-found

# Revertir auditoría (restaurar manifiesto original del API Server si se guardó backup)
# docker cp <backup> lab-calico-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml

helm uninstall sealed-secrets -n kube-system 2>/dev/null
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco --ignore-not-found
```

---

## Resumen

En este laboratorio se implementó una estrategia de seguridad en profundidad sobre el clúster Kubernetes:

| Control | Componente | Estado |
|---------|-----------|--------|
| **Autorización** | RBAC con 4 perfiles de mínimo privilegio | ✅ Aplicado |
| **Aislamiento de red** | Default-deny + allow-lists en 5 namespaces | ✅ Aplicado |
| **Gestión de secretos** | Sealed Secrets para encriptación en reposo | ✅ Aplicado |
| **Auditoría** | API Server audit logging multinivel | ✅ Configurado |
| **Escaneo de vulnerabilidades** | Trivy sobre imágenes y configuración | ✅ Ejecutado |
| **Runtime security** | Falco con reglas personalizadas | ✅ Desplegado |
| **Benchmark CIS** | kube-bench cis-1.9 | ✅ Documentado |
| **Hardening de pods** | SecurityContext vía kustomize overlays | ✅ Aplicado |

### Principios Clave Aplicados

1. **Mínimo privilegio**: cada identidad tiene solo los permisos estrictamente necesarios
2. **Defensa en profundidad**: múltiples capas de control (red, RBAC, runtime, auditoría)
3. **Seguridad como código**: todas las políticas son declarativas y versionables en Git
4. **Auditoría continua**: los audit logs y Falco proporcionan visibilidad en tiempo real

### Recursos Adicionales

- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [Kubernetes RBAC Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Sealed Secrets Documentation](https://github.com/bitnami-labs/sealed-secrets)
- [Falco Rules Reference](https://falco.org/docs/reference/rules/)
- [Kubernetes Audit Policy](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
