# Implementar Ingress Controller y Gateway con Certificados Gestionados

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 34 minutos |
| **Complejidad** | Media |
| **Nivel Bloom** | Aplicar |
| **Clúster** | lab-calico (contexto: kind-lab-calico) |
| **Directorio de trabajo** | ~/k8s-labs/lab02/ |

## Descripción General

En este laboratorio se instala NGINX Ingress Controller y cert-manager sobre el clúster `lab-calico` creado en el Lab 01, se despliega una aplicación multi-tier de referencia (`webapp`) y se configura el acceso externo con TLS gestionado automáticamente. Adicionalmente, se implementa la Gateway API como alternativa moderna al recurso Ingress, incluyendo enrutamiento basado en path, headers y despliegues canary.

## Objetivos de Aprendizaje

- [ ] Instalar y configurar NGINX Ingress Controller 1.10.1 con acceso via hostPort en el clúster kind
- [ ] Desplegar cert-manager 1.15.1 y crear ClusterIssuers (self-signed, CA) para gestión automatizada de certificados TLS
- [ ] Configurar recursos Ingress con terminación TLS usando certificados emitidos por cert-manager
- [ ] Implementar Gateway API 1.1.0 con HTTPRoute como alternativa al recurso Ingress clásico
- [ ] Aplicar políticas de enrutamiento avanzadas: path-based, header-based y canary deployments

## Prerrequisitos

### Conocimientos

- Familiaridad con conceptos de TLS/SSL y certificados X.509
- Comprensión del recurso Ingress y su relación con Services
- Experiencia básica con Helm para instalación de charts

### Acceso y Software

| Componente | Versión | Verificación |
|------------|---------|--------------|
| Clúster lab-calico | kind 0.23.0 / K8s 1.30.2 | `kubectl cluster-info --context kind-lab-calico` |
| Helm | 3.15.2 | `helm version --short` |
| kubectl | 1.30.2 | `kubectl version --client --short` |
| OpenSSL | 3.0.13+ | `openssl version` |
| Acceso root a /etc/hosts | — | `sudo test -w /etc/hosts && echo OK` |

## Entorno del Laboratorio

### Estructura de directorios

```
~/k8s-labs/lab02/
├── manifests/
│   ├── webapp/
│   ├── ingress/
│   ├── certs/
│   └── gateway/
└── values/
    ├── ingress-nginx-values.yaml
    └── cert-manager-values.yaml
```

### Dominios locales utilizados

| Dominio | Propósito |
|---------|-----------|
| webapp.lab.local | Frontend de la aplicación |
| api.lab.local | Backend API |
| *.lab.local | Wildcard para labs posteriores |

## Paso a Paso

### Paso 1: Preparar el directorio de trabajo y verificar el clúster

**Objetivo:** Crear la estructura de directorios y confirmar que el clúster lab-calico está operativo.

**Instrucciones:**

1. Cambiar al contexto del clúster:

```bash
kubectl config use-context kind-lab-calico
```

2. Crear la estructura de directorios:

```bash
mkdir -p ~/k8s-labs/lab02/{manifests/{webapp,ingress,certs,gateway},values}
cd ~/k8s-labs/lab02
```

3. Verificar que todos los nodos están Ready:

```bash
kubectl get nodes -o wide
```

4. Verificar que Calico está operativo:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
```

**Salida esperada:**

```
NAME                                  STATUS   ROLES           AGE   VERSION
lab-calico-control-plane              Ready    control-plane   ...   v1.30.2
lab-calico-worker                     Ready    <none>          ...   v1.30.2
lab-calico-worker2                    Ready    <none>          ...   v1.30.2
```

**Verificación:**

```bash
kubectl get nodes --no-headers | awk '{print $2}' | sort -u
# Debe mostrar solo: Ready
```

---

### Paso 2: Instalar NGINX Ingress Controller via Helm

**Objetivo:** Desplegar NGINX Ingress Controller 1.10.1 con hostPort habilitado para acceso directo desde el host.

**Instrucciones:**

1. Añadir el repositorio Helm (si no existe):

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

2. Crear el archivo de valores personalizado:

```bash
cat > ~/k8s-labs/lab02/values/ingress-nginx-values.yaml << 'EOF'
controller:
  image:
    tag: "v1.10.1"
  hostPort:
    enabled: true
  service:
    type: NodePort
  nodeSelector:
    ingress-ready: "true"
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Equal"
      effect: "NoSchedule"
  watchIngressWithoutClass: true
  ingressClassResource:
    name: nginx
    default: true
  config:
    use-forwarded-headers: "true"
    compute-full-forwarded-for: "true"
  admissionWebhooks:
    enabled: true
EOF
```

3. Etiquetar el nodo control-plane para el Ingress Controller:

```bash
kubectl label node lab-calico-control-plane ingress-ready=true --overwrite
```

4. Instalar el chart:

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version 4.10.1 \
  --values ~/k8s-labs/lab02/values/ingress-nginx-values.yaml \
  --wait --timeout 120s
```

**Salida esperada:**

```
NAME: ingress-nginx
...
STATUS: deployed
```

**Verificación:**

```bash
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
kubectl get ingressclass
```

El pod debe estar en estado `Running` y la IngressClass `nginx` debe aparecer como default.

---

### Paso 3: Instalar cert-manager 1.15.1

**Objetivo:** Desplegar cert-manager para gestión automatizada del ciclo de vida de certificados TLS.

**Instrucciones:**

1. Añadir el repositorio Helm:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

2. Crear el archivo de valores:

```bash
cat > ~/k8s-labs/lab02/values/cert-manager-values.yaml << 'EOF'
installCRDs: true
replicaCount: 1
webhook:
  replicaCount: 1
cainjector:
  replicaCount: 1
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
EOF
```

3. Instalar cert-manager:

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.1 \
  --values ~/k8s-labs/lab02/values/cert-manager-values.yaml \
  --wait --timeout 120s
```

4. Verificar que todos los componentes están listos:

```bash
kubectl get pods -n cert-manager
```

**Salida esperada:**

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxx-xxxxx              1/1     Running   0          ...
cert-manager-cainjector-xxxxxxxxx-xxxxx   1/1     Running   0          ...
cert-manager-webhook-xxxxxxxxx-xxxxx      1/1     Running   0          ...
```

**Verificación:**

```bash
kubectl get crds | grep cert-manager.io | wc -l
# Debe mostrar al menos 6 CRDs
```

---

### Paso 4: Crear ClusterIssuers y certificado wildcard

**Objetivo:** Configurar un ClusterIssuer self-signed, generar una CA root y crear un ClusterIssuer CA para emitir certificados de confianza interna.

**Instrucciones:**

1. Crear el ClusterIssuer self-signed (bootstrap):

```bash
cat > ~/k8s-labs/lab02/manifests/certs/clusterissuer-selfsigned.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/clusterissuer-selfsigned.yaml
```

2. Crear un Certificate para la CA root usando el issuer self-signed:

```bash
cat > ~/k8s-labs/lab02/manifests/certs/ca-certificate.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: lab-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "Lab Local CA"
  secretName: lab-ca-secret
  duration: 87600h  # 10 años
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/ca-certificate.yaml
```

3. Crear el ClusterIssuer CA que usa el secreto de la CA root:

```bash
cat > ~/k8s-labs/lab02/manifests/certs/clusterissuer-ca.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-ca-issuer
spec:
  ca:
    secretName: lab-ca-secret
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/clusterissuer-ca.yaml
```

4. Crear el certificado wildcard `*.lab.local`:

```bash
cat > ~/k8s-labs/lab02/manifests/certs/wildcard-certificate.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-lab-local
  namespace: ingress-nginx
spec:
  secretName: wildcard-lab-local-tls
  duration: 8760h  # 1 año
  renewBefore: 720h  # 30 días antes
  commonName: "*.lab.local"
  dnsNames:
    - "*.lab.local"
    - "lab.local"
  issuerRef:
    name: lab-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/wildcard-certificate.yaml
```

**Salida esperada:**

```
clusterissuer.cert-manager.io/selfsigned-issuer created
certificate.cert-manager.io/lab-ca created
clusterissuer.cert-manager.io/lab-ca-issuer created
certificate.cert-manager.io/wildcard-lab-local created
```

**Verificación:**

```bash
# Verificar que los certificados están en estado Ready
kubectl get certificates -A
kubectl get clusterissuers
```

Esperar hasta que la columna READY muestre `True` para ambos certificados:

```bash
kubectl wait --for=condition=Ready certificate/lab-ca -n cert-manager --timeout=60s
kubectl wait --for=condition=Ready certificate/wildcard-lab-local -n ingress-nginx --timeout=60s
```

---

### Paso 5: Desplegar la aplicación multi-tier webapp

**Objetivo:** Crear la aplicación de referencia con tres componentes (frontend, backend, api) que se usará en labs posteriores.

**Instrucciones:**

1. Crear el namespace:

```bash
kubectl create namespace webapp
kubectl label namespace webapp entorno=produccion
```

2. Crear el manifiesto de la aplicación completa:

```bash
cat > ~/k8s-labs/lab02/manifests/webapp/deployment.yaml << 'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-frontend
  namespace: webapp
  labels:
    app: webapp
    tier: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
      tier: frontend
  template:
    metadata:
      labels:
        app: webapp
        tier: frontend
    spec:
      containers:
        - name: frontend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      initContainers:
        - name: init-html
          image: busybox:1.36
          command: ['sh', '-c', 'echo "<html><body><h1>WebApp Frontend</h1><p>Hostname: $(hostname)</p></body></html>" > /html/index.html']
          volumeMounts:
            - name: html
              mountPath: /html
      volumes:
        - name: html
          emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-backend
  namespace: webapp
  labels:
    app: webapp
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
      tier: backend
  template:
    metadata:
      labels:
        app: webapp
        tier: backend
    spec:
      containers:
        - name: backend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      initContainers:
        - name: init-html
          image: busybox:1.36
          command: ['sh', '-c', 'echo "{\"service\":\"backend\",\"version\":\"v1\",\"hostname\":\"$(hostname)\"}" > /html/index.html && echo "{\"service\":\"backend\",\"version\":\"v1\",\"status\":\"healthy\"}" > /html/health']
          volumeMounts:
            - name: html
              mountPath: /html
      volumes:
        - name: html
          emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-api
  namespace: webapp
  labels:
    app: webapp
    tier: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
      tier: api
  template:
    metadata:
      labels:
        app: webapp
        tier: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      initContainers:
        - name: init-html
          image: busybox:1.36
          command: ['sh', '-c', 'mkdir -p /html/v1 /html/v2 && echo "{\"api\":\"v1\",\"hostname\":\"$(hostname)\"}" > /html/v1/index.html && echo "{\"api\":\"v2\",\"hostname\":\"$(hostname)\"}" > /html/v2/index.html']
          volumeMounts:
            - name: html
              mountPath: /html
      volumes:
        - name: html
          emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-api-canary
  namespace: webapp
  labels:
    app: webapp
    tier: api
    track: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webapp
      tier: api
      track: canary
  template:
    metadata:
      labels:
        app: webapp
        tier: api
        track: canary
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      initContainers:
        - name: init-html
          image: busybox:1.36
          command: ['sh', '-c', 'mkdir -p /html/v1 /html/v2 && echo "{\"api\":\"v2-canary\",\"hostname\":\"$(hostname)\"}" > /html/v1/index.html && echo "{\"api\":\"v2-canary\",\"hostname\":\"$(hostname)\"}" > /html/v2/index.html']
          volumeMounts:
            - name: html
              mountPath: /html
      volumes:
        - name: html
          emptyDir: {}
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/webapp/deployment.yaml
```

3. Crear los Services:

```bash
cat > ~/k8s-labs/lab02/manifests/webapp/services.yaml << 'EOF'
---
apiVersion: v1
kind: Service
metadata:
  name: webapp-frontend
  namespace: webapp
spec:
  selector:
    app: webapp
    tier: frontend
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: webapp-backend
  namespace: webapp
spec:
  selector:
    app: webapp
    tier: backend
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: webapp-api
  namespace: webapp
spec:
  selector:
    app: webapp
    tier: api
    track: stable
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: webapp-api-canary
  namespace: webapp
spec:
  selector:
    app: webapp
    tier: api
    track: canary
  ports:
    - port: 80
      targetPort: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/webapp/services.yaml
```

4. Añadir la etiqueta `track: stable` a los pods del api principal:

```bash
kubectl patch deployment webapp-api -n webapp --type='json' \
  -p='[{"op": "add", "path": "/spec/template/metadata/labels/track", "value": "stable"}]'
```

**Verificación:**

```bash
kubectl get pods -n webapp -o wide
kubectl get svc -n webapp
```

Todos los pods deben estar en estado `Running` (7 pods en total: 2 frontend + 2 backend + 2 api + 1 canary).

---

### Paso 6: Configurar entradas DNS locales

**Objetivo:** Añadir entradas en /etc/hosts para resolver los dominios del laboratorio hacia localhost.

**Instrucciones:**

1. Obtener la IP del nodo control-plane (en kind, el tráfico hostPort se expone en el contenedor Docker):

```bash
INGRESS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-calico-control-plane)
echo "IP del Ingress: $INGRESS_IP"
```

2. Añadir entradas a /etc/hosts:

```bash
sudo tee -a /etc/hosts > /dev/null << EOF
# Lab 02 - Kubernetes Ingress/Gateway
${INGRESS_IP} webapp.lab.local
${INGRESS_IP} api.lab.local
${INGRESS_IP} backend.lab.local
127.0.0.1 webapp.lab.local api.lab.local backend.lab.local
EOF
```

> **Nota:** Se añade también `127.0.0.1` como fallback. En kind con hostPort, el puerto 80/443 se mapea al host. Usaremos `curl --resolve` para pruebas directas contra la IP del contenedor.

**Verificación:**

```bash
grep "lab.local" /etc/hosts
```

---

### Paso 7: Crear Ingress con TLS y enrutamiento basado en path

**Objetivo:** Configurar un recurso Ingress con terminación TLS y enrutamiento path-based hacia los diferentes servicios de la webapp.

**Instrucciones:**

1. Crear el Ingress principal con TLS:

```bash
cat > ~/k8s-labs/lab02/manifests/ingress/webapp-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp-ingress
  namespace: webapp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    cert-manager.io/cluster-issuer: "lab-ca-issuer"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - webapp.lab.local
      secretName: webapp-tls
  rules:
    - host: webapp.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webapp-frontend
                port:
                  number: 80
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: webapp-api
                port:
                  number: 80
          - path: /api/v2
            pathType: Prefix
            backend:
              service:
                name: webapp-api
                port:
                  number: 80
          - path: /backend
            pathType: Prefix
            backend:
              service:
                name: webapp-backend
                port:
                  number: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/ingress/webapp-ingress.yaml
```

2. Crear el Ingress para el dominio api.lab.local con rewrite:

```bash
cat > ~/k8s-labs/lab02/manifests/ingress/api-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  namespace: webapp
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    cert-manager.io/cluster-issuer: "lab-ca-issuer"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.lab.local
      secretName: api-tls
  rules:
    - host: api.lab.local
      http:
        paths:
          - path: /v1(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: webapp-api
                port:
                  number: 80
          - path: /v2(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: webapp-api
                port:
                  number: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/ingress/api-ingress.yaml
```

3. Esperar a que cert-manager emita los certificados:

```bash
kubectl get certificates -n webapp --watch
# Esperar hasta que READY sea True, luego Ctrl+C
```

**Salida esperada:**

```
NAME         READY   SECRET       AGE
webapp-tls   True    webapp-tls   ...
api-tls      True    api-tls      ...
```

**Verificación:**

```bash
# Probar acceso HTTP (debe redirigir a HTTPS)
INGRESS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-calico-control-plane)

# Probar el frontend
curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} https://webapp.lab.local/ | head -5

# Probar la API
curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} https://webapp.lab.local/api/v1/

# Verificar el certificado TLS
echo | openssl s_client -connect ${INGRESS_IP}:443 -servername webapp.lab.local 2>/dev/null | openssl x509 -noout -subject -issuer
```

---

### Paso 8: Configurar Canary Deployment via Ingress Annotations

**Objetivo:** Implementar un despliegue canary usando anotaciones de NGINX Ingress para enviar un porcentaje del tráfico al servicio canary.

**Instrucciones:**

1. Crear el Ingress canary:

```bash
cat > ~/k8s-labs/lab02/manifests/ingress/canary-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp-api-canary
  namespace: webapp
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"
    nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
    nginx.ingress.kubernetes.io/canary-by-header-value: "always"
spec:
  ingressClassName: nginx
  rules:
    - host: webapp.lab.local
      http:
        paths:
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: webapp-api-canary
                port:
                  number: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/ingress/canary-ingress.yaml
```

**Verificación:**

```bash
INGRESS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-calico-control-plane)

# Tráfico normal (80% stable, 20% canary)
for i in $(seq 1 10); do
  curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} https://webapp.lab.local/api/v1/ 2>/dev/null
  echo ""
done

# Forzar canary con header
curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} \
  -H "X-Canary: always" \
  https://webapp.lab.local/api/v1/
```

Se debe observar que aproximadamente 2 de cada 10 requests devuelven `v2-canary`, y que el header `X-Canary: always` siempre enruta al canary.

---

### Paso 9: Instalar Gateway API CRDs e implementar HTTPRoute

**Objetivo:** Instalar los CRDs de Gateway API 1.1.0 y configurar un Gateway con HTTPRoute como alternativa moderna al recurso Ingress.

**Instrucciones:**

1. Instalar los CRDs de Gateway API:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

2. Verificar la instalación de CRDs:

```bash
kubectl get crds | grep gateway.networking.k8s.io
```

3. Crear el GatewayClass que usa NGINX como controlador:

```bash
cat > ~/k8s-labs/lab02/manifests/gateway/gatewayclass.yaml << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: k8s.io/ingress-nginx
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/gateway/gatewayclass.yaml
```

4. Crear el recurso Gateway:

```bash
cat > ~/k8s-labs/lab02/manifests/gateway/gateway.yaml << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: ingress-nginx
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              entorno: produccion
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-lab-local-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              entorno: produccion
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/gateway/gateway.yaml
```

5. Crear HTTPRoutes para la webapp:

```bash
cat > ~/k8s-labs/lab02/manifests/gateway/httproutes.yaml << 'EOF'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp-frontend-route
  namespace: webapp
spec:
  parentRefs:
    - name: lab-gateway
      namespace: ingress-nginx
      sectionName: https
  hostnames:
    - "webapp.lab.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: webapp-frontend
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp-api-route
  namespace: webapp
spec:
  parentRefs:
    - name: lab-gateway
      namespace: ingress-nginx
      sectionName: https
  hostnames:
    - "api.lab.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: webapp-api
          port: 80
          weight: 80
        - name: webapp-api-canary
          port: 80
          weight: 20
    - matches:
        - path:
            type: PathPrefix
            value: /v2
      backendRefs:
        - name: webapp-api
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp-header-route
  namespace: webapp
spec:
  parentRefs:
    - name: lab-gateway
      namespace: ingress-nginx
      sectionName: https
  hostnames:
    - "api.lab.local"
  rules:
    - matches:
        - headers:
            - name: X-Version
              value: canary
          path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: webapp-api-canary
          port: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/gateway/httproutes.yaml
```

**Salida esperada:**

```
gatewayclass.gateway.networking.k8s.io/nginx created
gateway.gateway.networking.k8s.io/lab-gateway created
httproute.gateway.networking.k8s.io/webapp-frontend-route created
httproute.gateway.networking.k8s.io/webapp-api-route created
httproute.gateway.networking.k8s.io/webapp-header-route created
```

**Verificación:**

```bash
# Verificar el estado del Gateway
kubectl get gateway -n ingress-nginx

# Verificar las HTTPRoutes
kubectl get httproutes -n webapp

# Verificar que las rutas están aceptadas
kubectl describe httproute webapp-api-route -n webapp | grep -A5 "Status:"
```

> **Nota:** El soporte de Gateway API en NGINX Ingress Controller 1.10.1 es experimental/beta. Los recursos se crean correctamente pero el enrutamiento efectivo puede requerir la versión del controlador con feature gate habilitado. Los recursos quedan declarados para uso con controladores compatibles en labs futuros.

---

### Paso 10: Verificar enrutamiento basado en headers

**Objetivo:** Demostrar el enrutamiento basado en headers como política avanzada, tanto con Ingress annotations como con Gateway API.

**Instrucciones:**

1. Crear un Ingress adicional con enrutamiento por header (complementario al canary):

```bash
cat > ~/k8s-labs/lab02/manifests/ingress/header-routing-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp-header-routing
  namespace: webapp
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-header: "X-Backend-Override"
    nginx.ingress.kubernetes.io/canary-by-header-value: "backend-v2"
spec:
  ingressClassName: nginx
  rules:
    - host: webapp.lab.local
      http:
        paths:
          - path: /backend
            pathType: Prefix
            backend:
              service:
                name: webapp-api-canary
                port:
                  number: 80
EOF
kubectl apply -f ~/k8s-labs/lab02/manifests/ingress/header-routing-ingress.yaml
```

**Verificación:**

```bash
INGRESS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-calico-control-plane)

# Sin header - va al backend normal
curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} https://webapp.lab.local/backend/

# Con header - va al canary
curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} \
  -H "X-Backend-Override: backend-v2" \
  https://webapp.lab.local/backend/
```

---

## Validación y Testing

Ejecutar el siguiente script de validación completa:

```bash
#!/bin/bash
echo "=== Validación Lab 02 ==="
INGRESS_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-calico-control-plane)
PASS=0
FAIL=0

# Test 1: NGINX Ingress Controller running
echo -n "[1/8] NGINX Ingress Controller: "
if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers | grep -q Running; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL"; ((FAIL++))
fi

# Test 2: cert-manager pods running
echo -n "[2/8] cert-manager operativo: "
CM_READY=$(kubectl get pods -n cert-manager --no-headers | grep Running | wc -l)
if [ "$CM_READY" -ge 3 ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL ($CM_READY/3 pods)"; ((FAIL++))
fi

# Test 3: ClusterIssuers ready
echo -n "[3/8] ClusterIssuers configurados: "
ISSUERS=$(kubectl get clusterissuers --no-headers | grep True | wc -l)
if [ "$ISSUERS" -ge 2 ]; then
  echo "PASS ($ISSUERS issuers)"; ((PASS++))
else
  echo "FAIL ($ISSUERS/2 issuers)"; ((FAIL++))
fi

# Test 4: Wildcard certificate ready
echo -n "[4/8] Certificado wildcard: "
if kubectl get certificate wildcard-lab-local -n ingress-nginx -o jsonpath='{.status.conditions[0].status}' | grep -q True; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL"; ((FAIL++))
fi

# Test 5: Webapp pods running
echo -n "[5/8] Webapp pods (7 expected): "
WEBAPP_PODS=$(kubectl get pods -n webapp --no-headers | grep Running | wc -l)
if [ "$WEBAPP_PODS" -ge 7 ]; then
  echo "PASS ($WEBAPP_PODS pods)"; ((PASS++))
else
  echo "FAIL ($WEBAPP_PODS/7 pods)"; ((FAIL++))
fi

# Test 6: TLS certificate issued for webapp
echo -n "[6/8] Certificado TLS webapp: "
if kubectl get certificate webapp-tls -n webapp -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL"; ((FAIL++))
fi

# Test 7: Ingress responding with HTTPS
echo -n "[7/8] HTTPS accesible: "
HTTP_CODE=$(curl -sk --resolve webapp.lab.local:443:${INGRESS_IP} -o /dev/null -w "%{http_code}" https://webapp.lab.local/ 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS (HTTP $HTTP_CODE)"; ((PASS++))
else
  echo "FAIL (HTTP $HTTP_CODE)"; ((FAIL++))
fi

# Test 8: Gateway API CRDs installed
echo -n "[8/8] Gateway API CRDs: "
GW_CRDS=$(kubectl get crds | grep -c gateway.networking.k8s.io)
if [ "$GW_CRDS" -ge 4 ]; then
  echo "PASS ($GW_CRDS CRDs)"; ((PASS++))
else
  echo "FAIL ($GW_CRDS CRDs)"; ((FAIL++))
fi

echo ""
echo "=== Resultado: $PASS/8 tests pasados, $FAIL fallidos ==="
```

Guardar y ejecutar:

```bash
cat > ~/k8s-labs/lab02/validate.sh << 'SCRIPT'
# (pegar el script anterior aquí)
SCRIPT
chmod +x ~/k8s-labs/lab02/validate.sh
bash ~/k8s-labs/lab02/validate.sh
```

**Resultado esperado:** 8/8 tests pasados.

---

## Resolución de Problemas

### Problema 1: Los certificados quedan en estado "Not Ready" indefinidamente

**Síntomas:**
```
$ kubectl get certificates -A
NAME                   READY   SECRET                   AGE
wildcard-lab-local     False   wildcard-lab-local-tls   5m
```

**Causa:** El ClusterIssuer `lab-ca-issuer` no puede encontrar el secreto `lab-ca-secret` porque el Certificate de la CA aún no se ha emitido (dependencia circular o el issuer self-signed no está listo).

**Solución:**

```bash
# 1. Verificar el estado del ClusterIssuer self-signed
kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[0]}'

# 2. Verificar que el certificado CA se emitió correctamente
kubectl get certificate lab-ca -n cert-manager -o yaml | grep -A10 status

# 3. Si el secreto no existe, recrear el certificado CA
kubectl delete certificate lab-ca -n cert-manager
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/ca-certificate.yaml

# 4. Esperar y verificar
kubectl wait --for=condition=Ready certificate/lab-ca -n cert-manager --timeout=90s

# 5. Forzar re-emisión del wildcard
kubectl delete certificate wildcard-lab-local -n ingress-nginx
kubectl apply -f ~/k8s-labs/lab02/manifests/certs/wildcard-certificate.yaml
```

---

### Problema 2: curl devuelve "connection refused" al acceder al Ingress

**Síntomas:**
```
$ curl -sk https://webapp.lab.local/
curl: (7) Failed to connect to webapp.lab.local port 443: Connection refused
```

**Causa:** El pod del NGINX Ingress Controller no tiene hostPort configurado correctamente o no está programado en el nodo etiquetado con `ingress-ready=true`.

**Solución:**

```bash
# 1. Verificar en qué nodo está el pod del controlador
kubectl get pods -n ingress-nginx -o wide

# 2. Verificar que el nodo tiene la etiqueta correcta
kubectl get nodes --show-labels | grep ingress-ready

# 3. Si el pod no está en el control-plane, verificar la etiqueta
kubectl label node lab-calico-control-plane ingress-ready=true --overwrite

# 4. Verificar que hostPort está activo en el pod
kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.containers[0].ports}' | python3 -m json.tool

# 5. Si hostPort no aparece, reinstalar con los valores correctos
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values ~/k8s-labs/lab02/values/ingress-nginx-values.yaml \
  --wait

# 6. Verificar conectividad directa al contenedor Docker
docker exec lab-calico-control-plane ss -tlnp | grep -E "80|443"
```

---

## Limpieza

> **⚠️ NO ejecutar la limpieza si se planea continuar con los Labs 03-10.** La aplicación webapp, los certificados y el Ingress Controller son prerrequisitos para los labs posteriores.

Si se desea limpiar completamente el lab (solo para reinicio):

```bash
# Eliminar HTTPRoutes y Gateway
kubectl delete -f ~/k8s-labs/lab02/manifests/gateway/ --ignore-not-found

# Eliminar Ingress resources
kubectl delete -f ~/k8s-labs/lab02/manifests/ingress/ --ignore-not-found

# Eliminar webapp
kubectl delete namespace webapp --ignore-not-found

# Eliminar certificados
kubectl delete -f ~/k8s-labs/lab02/manifests/certs/ --ignore-not-found

# Desinstalar cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager

# Desinstalar NGINX Ingress
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx

# Eliminar Gateway API CRDs
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# Limpiar /etc/hosts
sudo sed -i '/lab.local/d' /etc/hosts

# Eliminar directorio
rm -rf ~/k8s-labs/lab02/
```

---

## Resumen

En este laboratorio se implementó una infraestructura completa de Ingress y gestión de certificados:

| Componente | Estado | Propósito |
|------------|--------|-----------|
| NGINX Ingress Controller 1.10.1 | Desplegado en `ingress-nginx` | Proxy inverso con hostPort |
| cert-manager 1.15.1 | Desplegado en `cert-manager` | Gestión automatizada de TLS |
| ClusterIssuer self-signed | Activo | Bootstrap para CA root |
| ClusterIssuer lab-ca-issuer | Activo | Emisión de certificados internos |
| Certificado wildcard *.lab.local | Emitido | Disponible para labs 03-10 |
| Webapp multi-tier | Running en `webapp` | Aplicación de referencia |
| Gateway API 1.1.0 CRDs | Instalados | Alternativa moderna a Ingress |

**Conceptos clave aplicados:**

- **Separación de responsabilidades:** La Gateway API divide la gestión entre GatewayClass (infraestructura), Gateway (operadores) y HTTPRoute (desarrolladores), eliminando la dependencia de anotaciones específicas del controlador.
- **Canary deployments:** Se implementaron tanto con anotaciones de NGINX (`canary-weight`, `canary-by-header`) como con `backendRefs` con `weight` en HTTPRoute.
- **Gestión de certificados declarativa:** cert-manager automatiza la emisión y renovación de certificados mediante CRDs, eliminando la gestión manual de TLS.

### Recursos Adicionales

- [Documentación oficial Gateway API](https://gateway-api.sigs.k8s.io/)
- [NGINX Ingress Controller Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [cert-manager Configuration](https://cert-manager.io/docs/configuration/)
- [Gateway API vs Ingress: comparativa oficial](https://gateway-api.sigs.k8s.io/concepts/migrating-from-ingress/)
