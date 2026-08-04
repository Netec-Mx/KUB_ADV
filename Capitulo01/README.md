# Desplegar y Evaluar CNIs (Calico, Cilium)

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 29 minutos |
| **Complejidad** | Media |
| **Nivel Bloom** | Aplicar |

## Descripción General

En este laboratorio desplegarás dos clústeres Kubernetes multi-nodo usando kind, cada uno con un plugin CNI diferente: Calico (basado en BGP/IPAM) y Cilium (basado en eBPF). Configurarás IPPools personalizados, implementarás NetworkPolicies de aislamiento entre namespaces y medirás el rendimiento de red con iperf3 para comparar ambas soluciones. El clúster `lab-calico` quedará activo como infraestructura base para los laboratorios posteriores del curso.

## Objetivos de Aprendizaje

- [ ] Desplegar clústeres kind multi-nodo sin CNI por defecto y configurar plugins CNI externos
- [ ] Instalar Calico 3.28.0 con IPPool personalizado (CIDR 192.168.0.0/16) y validar conectividad
- [ ] Instalar Cilium 1.15.6 con eBPF en un clúster alternativo y verificar su operación
- [ ] Implementar NetworkPolicies de deny-all y allow-selective en ambos CNIs
- [ ] Comparar rendimiento de red entre Calico y Cilium usando iperf3

## Prerrequisitos

### Conocimientos Requeridos

- Conceptos básicos de redes TCP/IP (CIDR, routing, VXLAN)
- Familiaridad con kubectl y manifiestos YAML de Kubernetes
- Comprensión del modelo de red plana de Kubernetes y la especificación CNI

### Acceso y Software Instalado

| Componente | Versión | Verificación |
|------------|---------|--------------|
| Ubuntu 22.04 LTS | kernel >= 5.15 | `uname -r` |
| Docker Engine | 26.1.4 | `docker --version` |
| kubectl | 1.30.2 | `kubectl version --client` |
| kind | 0.23.0 | `kind --version` |
| Helm | 3.15.2 | `helm version --short` |
| Cilium CLI | 0.16.10 | `cilium version --client` |
| calicoctl | 3.28.0 | `calicoctl version` |

## Entorno del Laboratorio

### Configuración del Sistema

```bash
# Verificar parámetros del kernel requeridos
sysctl net.ipv4.ip_forward
# Salida esperada: net.ipv4.ip_forward = 1

sysctl vm.max_map_count
# Salida esperada: vm.max_map_count = 262144
```

### Estructura de Directorios

```bash
# Crear directorio de trabajo para este lab
mkdir -p ~/k8s-labs/lab01/{calico,cilium,nettest,policies}
cd ~/k8s-labs/lab01
```

---

## Paso 1: Crear el Clúster kind para Calico

**Objetivo:** Desplegar un clúster kind de 3 nodos (1 control-plane + 2 workers) sin CNI por defecto, preparado para instalar Calico externamente.

### Instrucciones

1. Crea el archivo de configuración kind para el clúster Calico:

```bash
cat > ~/k8s-labs/lab01/calico/kind-calico.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab-calico
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
EOF
```

2. Crea el clúster:

```bash
kind create cluster --config ~/k8s-labs/lab01/calico/kind-calico.yaml
```

3. Verifica que el contexto está activo:

```bash
kubectl cluster-info --context kind-lab-calico
```

### Salida Esperada

```
Kubernetes control plane is running at https://127.0.0.1:XXXXX
CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

### Verificación

```bash
# Los nodos estarán en NotReady hasta instalar el CNI
kubectl get nodes
```

Salida esperada (todos en `NotReady`):

```
NAME                       STATUS     ROLES           AGE   VERSION
lab-calico-control-plane   NotReady   control-plane   30s   v1.30.2
lab-calico-worker          NotReady   <none>          20s   v1.30.2
lab-calico-worker2         NotReady   <none>          20s   v1.30.2
```

---

## Paso 2: Instalar Calico 3.28.0 con IPPool Personalizado

**Objetivo:** Instalar Calico como CNI y configurar un IPPool con CIDR 192.168.0.0/16 usando encapsulación VXLAN.

### Instrucciones

1. Aplica el manifiesto del operador de Calico:

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
```

2. Crea la configuración de instalación personalizada con el IPPool:

```bash
cat > ~/k8s-labs/lab01/calico/calico-installation.yaml << 'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: 192.168.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
    nodeAddressAutodetectionV4:
      firstFound: true
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

3. Aplica la configuración:

```bash
kubectl apply -f ~/k8s-labs/lab01/calico/calico-installation.yaml
```

4. Espera a que todos los componentes de Calico estén listos:

```bash
kubectl wait --for=condition=Ready pods --all -n calico-system --timeout=120s
```

5. Verifica que los nodos pasen a estado `Ready`:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```

### Salida Esperada

```
node/lab-calico-control-plane condition met
node/lab-calico-worker condition met
node/lab-calico-worker2 condition met
```

### Verificación

```bash
# Verificar pods de Calico
kubectl get pods -n calico-system

# Verificar el IPPool con calicoctl
calicoctl get ippools -o wide --allow-version-mismatch
```

Salida esperada del IPPool:

```
NAME                     CIDR              NAT    IPIPMODE   VXLANMODE          DISABLED
default-ipv4-ippool      192.168.0.0/16    true   Never      CrossSubnet        false
```

---

## Paso 3: Desplegar Aplicación de Prueba en el Clúster Calico

**Objetivo:** Crear un namespace de prueba con pods de diagnóstico para validar la conectividad de red proporcionada por Calico.

### Instrucciones

1. Crea el namespace y los pods de prueba:

```bash
cat > ~/k8s-labs/lab01/nettest/nettest-calico.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: network-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettest-server
  namespace: network-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nettest
      role: server
  template:
    metadata:
      labels:
        app: nettest
        role: server
    spec:
      containers:
        - name: nettest
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "infinity"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettest-client
  namespace: network-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nettest
      role: client
  template:
    metadata:
      labels:
        app: nettest
        role: client
    spec:
      containers:
        - name: nettest
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "infinity"]
EOF
```

2. Aplica el manifiesto:

```bash
kubectl apply -f ~/k8s-labs/lab01/nettest/nettest-calico.yaml
```

3. Espera a que los pods estén listos:

```bash
kubectl wait --for=condition=Ready pods --all -n network-test --timeout=90s
```

4. Verifica la conectividad entre pods:

```bash
# Obtener IP de un pod servidor
SERVER_IP=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].status.podIP}')
echo "Server IP: $SERVER_IP"

# Desde el cliente, hacer ping al servidor
CLIENT_POD=$(kubectl get pods -n network-test -l role=client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n network-test $CLIENT_POD -- ping -c 3 $SERVER_IP
```

### Salida Esperada

```
PING 192.168.x.x (192.168.x.x) 56(84) bytes of data.
64 bytes from 192.168.x.x: icmp_seq=1 ttl=62 time=0.XXX ms
64 bytes from 192.168.x.x: icmp_seq=2 ttl=62 time=0.XXX ms
64 bytes from 192.168.x.x: icmp_seq=3 ttl=62 time=0.XXX ms
--- 192.168.x.x ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

### Verificación

```bash
# Confirmar que las IPs asignadas pertenecen al CIDR configurado
kubectl get pods -n network-test -o wide
```

Todas las IPs de los pods deben estar en el rango `192.168.0.0/16`.

---

## Paso 4: Crear el Clúster kind para Cilium

**Objetivo:** Desplegar un segundo clúster kind para instalar Cilium como CNI alternativo basado en eBPF.

### Instrucciones

1. Crea el archivo de configuración kind para Cilium:

```bash
cat > ~/k8s-labs/lab01/cilium/kind-cilium.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab-cilium
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
EOF
```

2. Crea el clúster:

```bash
kind create cluster --config ~/k8s-labs/lab01/cilium/kind-cilium.yaml
```

3. Verifica que el contexto se cambió automáticamente:

```bash
kubectl config current-context
# Salida: kind-lab-cilium
```

### Salida Esperada

```
Creating cluster "lab-cilium" ...
 ✓ Ensuring node image (kindest/node:v1.30.2) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-lab-cilium"
```

### Verificación

```bash
kubectl get nodes --context kind-lab-cilium
```

Todos los nodos deben estar en `NotReady` (sin CNI instalado).

---

## Paso 5: Instalar Cilium 1.15.6 con eBPF

**Objetivo:** Instalar Cilium usando Helm con reemplazo de kube-proxy y Hubble habilitado para observabilidad.

### Instrucciones

1. Agrega el repositorio Helm de Cilium:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

2. Instala Cilium 1.15.6:

```bash
helm install cilium cilium/cilium \
  --version 1.15.6 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=lab-cilium-control-plane \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=false
```

3. Espera a que Cilium esté operativo:

```bash
kubectl wait --for=condition=Ready pods -l k8s-app=cilium -n kube-system --timeout=120s
```

4. Verifica el estado con Cilium CLI:

```bash
cilium status --wait
```

### Salida Esperada

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    disabled (using embedded mode)
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

Deployment             cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1
```

### Verificación

```bash
# Verificar que los nodos están Ready
kubectl get nodes
```

Todos los nodos deben mostrar `Ready`.

---

## Paso 6: Desplegar Aplicación de Prueba en el Clúster Cilium

**Objetivo:** Replicar la aplicación de prueba en el clúster Cilium para realizar comparaciones equivalentes.

### Instrucciones

1. Aplica el mismo manifiesto de prueba (adaptado al contexto Cilium):

```bash
kubectl apply -f ~/k8s-labs/lab01/nettest/nettest-calico.yaml --context kind-lab-cilium
```

2. Espera a que los pods estén listos:

```bash
kubectl wait --for=condition=Ready pods --all -n network-test --timeout=90s --context kind-lab-cilium
```

3. Verifica la conectividad:

```bash
SERVER_IP=$(kubectl get pods -n network-test -l role=server --context kind-lab-cilium -o jsonpath='{.items[0].status.podIP}')
CLIENT_POD=$(kubectl get pods -n network-test -l role=client --context kind-lab-cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n network-test $CLIENT_POD --context kind-lab-cilium -- ping -c 3 $SERVER_IP
```

### Salida Esperada

```
3 packets transmitted, 3 received, 0% packet loss
```

### Verificación

```bash
# Las IPs deben estar en el rango 10.244.0.0/16
kubectl get pods -n network-test -o wide --context kind-lab-cilium
```

---

## Paso 7: Medir Rendimiento de Red con iperf3

**Objetivo:** Ejecutar pruebas de throughput con iperf3 en ambos clústeres para comparar el rendimiento de Calico vs. Cilium.

### Instrucciones

1. **Prueba en el clúster Calico:**

```bash
kubectl config use-context kind-lab-calico

# Obtener nombres de pods
SERVER_POD=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].metadata.name}')
CLIENT_POD=$(kubectl get pods -n network-test -l role=client -o jsonpath='{.items[0].metadata.name}')
SERVER_IP=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].status.podIP}')

# Iniciar servidor iperf3
kubectl exec -n network-test $SERVER_POD -- iperf3 -s -D -p 5201

# Esperar 2 segundos para que inicie
sleep 2

# Ejecutar prueba desde el cliente (10 segundos)
kubectl exec -n network-test $CLIENT_POD -- iperf3 -c $SERVER_IP -p 5201 -t 10 -J | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Calico Throughput: {d[\"end\"][\"sum_received\"][\"bits_per_second\"]/1e9:.2f} Gbps')"
```

2. **Prueba en el clúster Cilium:**

```bash
kubectl config use-context kind-lab-cilium

SERVER_POD=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].metadata.name}')
CLIENT_POD=$(kubectl get pods -n network-test -l role=client -o jsonpath='{.items[0].metadata.name}')
SERVER_IP=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].status.podIP}')

# Iniciar servidor iperf3
kubectl exec -n network-test $SERVER_POD -- iperf3 -s -D -p 5201

sleep 2

# Ejecutar prueba desde el cliente
kubectl exec -n network-test $CLIENT_POD -- iperf3 -c $SERVER_IP -p 5201 -t 10 -J | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Cilium Throughput: {d[\"end\"][\"sum_received\"][\"bits_per_second\"]/1e9:.2f} Gbps')"
```

### Salida Esperada

Los valores varían según el hardware. Ejemplo típico en entornos kind:

```
Calico Throughput: 8.52 Gbps
Cilium Throughput: 9.14 Gbps
```

> **Nota:** En entornos kind (red loopback de Docker), las diferencias son menores que en hardware real. Cilium con eBPF generalmente muestra una ventaja de 5-15% en latencia y throughput en clústeres bare-metal.

### Verificación

Ambas pruebas deben completarse sin errores de conexión, confirmando que la red de pods funciona correctamente en ambos CNIs.

---

## Paso 8: Implementar NetworkPolicies en Calico

**Objetivo:** Aplicar políticas de red de deny-all y allow-selective en el clúster Calico para demostrar el aislamiento entre namespaces.

### Instrucciones

1. Cambia al contexto Calico y crea un segundo namespace:

```bash
kubectl config use-context kind-lab-calico

kubectl create namespace network-isolated
```

2. Despliega un pod en el namespace aislado:

```bash
cat > ~/k8s-labs/lab01/policies/isolated-pod.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: isolated-client
  namespace: network-isolated
  labels:
    app: isolated
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
EOF

kubectl apply -f ~/k8s-labs/lab01/policies/isolated-pod.yaml
kubectl wait --for=condition=Ready pod/isolated-client -n network-isolated --timeout=60s
```

3. Verifica que SIN política, la comunicación entre namespaces es posible:

```bash
SERVER_IP=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n network-isolated isolated-client -- ping -c 2 -W 3 $SERVER_IP
# Debe funcionar (0% packet loss)
```

4. Aplica una política deny-all de ingress en `network-test`:

```bash
cat > ~/k8s-labs/lab01/policies/deny-all-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: network-test
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF

kubectl apply -f ~/k8s-labs/lab01/policies/deny-all-ingress.yaml
```

5. Verifica que la comunicación está bloqueada:

```bash
kubectl exec -n network-isolated isolated-client -- ping -c 2 -W 3 $SERVER_IP
# Debe fallar (100% packet loss o timeout)
```

6. Aplica una política selectiva que permita tráfico solo desde pods con label `role=client` en el mismo namespace:

```bash
cat > ~/k8s-labs/lab01/policies/allow-internal-clients.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internal-clients
  namespace: network-test
spec:
  podSelector:
    matchLabels:
      role: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: network-test
          podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 5201
EOF

kubectl apply -f ~/k8s-labs/lab01/policies/allow-internal-clients.yaml
```

7. Verifica que el cliente interno puede comunicarse:

```bash
CLIENT_POD=$(kubectl get pods -n network-test -l role=client -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n network-test $CLIENT_POD -- ping -c 2 -W 3 $SERVER_IP
# Nota: ping usa ICMP que no está en la política allow; probemos TCP
kubectl exec -n network-test $CLIENT_POD -- nc -zv $SERVER_IP 5201 -w 3
```

### Salida Esperada

Paso 5 (bloqueado):
```
PING 192.168.x.x (192.168.x.x) 56(84) bytes of data.
--- 192.168.x.x ping statistics ---
2 packets transmitted, 0 received, 100% packet loss
```

Paso 7 (permitido en TCP 5201 para client interno — verificar que el servidor iperf3 sigue corriendo):
```
Connection to 192.168.x.x 5201 port [tcp/*] succeeded!
```

### Verificación

```bash
# Listar NetworkPolicies activas
kubectl get networkpolicies -n network-test
```

```
NAME                      POD-SELECTOR   AGE
deny-all-ingress          <none>         2m
allow-internal-clients    role=server    1m
```

---

## Paso 9: Implementar NetworkPolicies en Cilium

**Objetivo:** Replicar las políticas de red en el clúster Cilium para comparar el enforcement y validar que ambos CNIs soportan la API estándar de NetworkPolicy.

### Instrucciones

1. Cambia al contexto Cilium:

```bash
kubectl config use-context kind-lab-cilium
```

2. Crea el namespace aislado y el pod:

```bash
kubectl create namespace network-isolated
kubectl apply -f ~/k8s-labs/lab01/policies/isolated-pod.yaml
kubectl wait --for=condition=Ready pod/isolated-client -n network-isolated --timeout=60s
```

3. Verifica comunicación sin políticas:

```bash
SERVER_IP=$(kubectl get pods -n network-test -l role=server -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n network-isolated isolated-client -- ping -c 2 -W 3 $SERVER_IP
# Debe funcionar
```

4. Aplica la política deny-all:

```bash
kubectl apply -f ~/k8s-labs/lab01/policies/deny-all-ingress.yaml
```

5. Verifica el bloqueo:

```bash
kubectl exec -n network-isolated isolated-client -- ping -c 2 -W 3 $SERVER_IP
# Debe fallar
```

6. Aplica la política selectiva:

```bash
kubectl apply -f ~/k8s-labs/lab01/policies/allow-internal-clients.yaml
```

7. Verifica el enforcement con Cilium:

```bash
# Verificar que Cilium ha procesado las políticas
cilium policy get -n network-test 2>/dev/null || kubectl get cnp -A
```

### Salida Esperada

El comportamiento debe ser idéntico al clúster Calico: deny-all bloquea todo el ingress, y la política selectiva permite tráfico TCP 5201 solo desde pods con `role=client` en el namespace `network-test`.

### Verificación

```bash
kubectl get networkpolicies -n network-test --context kind-lab-cilium
```

---

## Paso 10: Establecer Contexto Principal para Labs Posteriores

**Objetivo:** Configurar el clúster `lab-calico` como contexto activo por defecto para los laboratorios subsiguientes.

### Instrucciones

1. Cambia al contexto del clúster Calico:

```bash
kubectl config use-context kind-lab-calico
```

2. Verifica el contexto activo:

```bash
kubectl config current-context
```

3. Confirma el estado del clúster:

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -E "calico|coredns"
```

### Salida Esperada

```
kind-lab-calico
```

```
NAME                       STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
lab-calico-control-plane   Ready    control-plane   15m   v1.30.2   172.18.0.x    ...
lab-calico-worker          Ready    <none>          14m   v1.30.2   172.18.0.x    ...
lab-calico-worker2         Ready    <none>          14m   v1.30.2   172.18.0.x    ...
```

---

## Validación y Pruebas Finales

Ejecuta el siguiente script de validación integral:

```bash
#!/bin/bash
echo "=== Validación Final del Lab 01 ==="
echo ""

# Test 1: Clúster Calico operativo
echo "[1/5] Verificando clúster lab-calico..."
CALICO_NODES=$(kubectl get nodes --context kind-lab-calico --no-headers | grep -c "Ready")
if [ "$CALICO_NODES" -eq 3 ]; then
  echo "  ✓ 3 nodos Ready en lab-calico"
else
  echo "  ✗ Esperados 3 nodos Ready, encontrados: $CALICO_NODES"
fi

# Test 2: Calico CNI funcionando
echo "[2/5] Verificando Calico CNI..."
CALICO_PODS=$(kubectl get pods -n calico-system --context kind-lab-calico --no-headers | grep -c "Running")
if [ "$CALICO_PODS" -ge 3 ]; then
  echo "  ✓ Calico pods operativos: $CALICO_PODS"
else
  echo "  ✗ Calico pods insuficientes: $CALICO_PODS"
fi

# Test 3: Clúster Cilium operativo
echo "[3/5] Verificando clúster lab-cilium..."
CILIUM_NODES=$(kubectl get nodes --context kind-lab-cilium --no-headers | grep -c "Ready")
if [ "$CILIUM_NODES" -eq 3 ]; then
  echo "  ✓ 3 nodos Ready en lab-cilium"
else
  echo "  ✗ Esperados 3 nodos Ready, encontrados: $CILIUM_NODES"
fi

# Test 4: NetworkPolicies en Calico
echo "[4/5] Verificando NetworkPolicies en lab-calico..."
NP_COUNT=$(kubectl get networkpolicies -n network-test --context kind-lab-calico --no-headers | wc -l)
if [ "$NP_COUNT" -ge 2 ]; then
  echo "  ✓ NetworkPolicies aplicadas: $NP_COUNT"
else
  echo "  ✗ NetworkPolicies insuficientes: $NP_COUNT"
fi

# Test 5: Contexto activo correcto
echo "[5/5] Verificando contexto activo..."
CURRENT=$(kubectl config current-context)
if [ "$CURRENT" = "kind-lab-calico" ]; then
  echo "  ✓ Contexto activo: kind-lab-calico"
else
  echo "  ✗ Contexto incorrecto: $CURRENT (esperado: kind-lab-calico)"
fi

echo ""
echo "=== Validación completada ==="
```

Guarda y ejecuta:

```bash
cat > ~/k8s-labs/lab01/validate.sh << 'SCRIPT'
# (pegar el script de arriba)
SCRIPT
chmod +x ~/k8s-labs/lab01/validate.sh
bash ~/k8s-labs/lab01/validate.sh
```

**Resultado esperado:** Todos los checks deben mostrar `✓`.

---

## Solución de Problemas

### Problema 1: Los nodos permanecen en NotReady después de instalar Calico

**Síntomas:**
- `kubectl get nodes` muestra `NotReady` después de 2+ minutos de instalar Calico.
- Los pods `calico-node` en `calico-system` están en `CrashLoopBackOff` o `Init:0/1`.

**Causa:**
El operador Tigera no puede detectar la interfaz de red correcta en los nodos kind, o el `podSubnet` configurado en kind no coincide con el CIDR del IPPool de Calico.

**Solución:**

```bash
# Verificar logs del operador
kubectl logs -n tigera-operator -l k8s-app=tigera-operator --tail=50

# Verificar que el podSubnet de kind coincide con el CIDR del IPPool
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.ipPools[0].cidr}'
# Debe ser: 192.168.0.0/16

# Si hay conflicto, eliminar la instalación y reaplicar
kubectl delete installation default
kubectl apply -f ~/k8s-labs/lab01/calico/calico-installation.yaml

# Verificar que los nodos kind tienen IP forwarding habilitado
docker exec lab-calico-control-plane sysctl net.ipv4.ip_forward
# Debe ser: net.ipv4.ip_forward = 1
```

### Problema 2: Cilium CLI muestra "Unreachable" en connectivity test

**Síntomas:**
- `cilium status` muestra componentes OK pero `cilium connectivity test` falla con errores de conectividad entre nodos.
- Los pods en diferentes workers no pueden comunicarse.

**Causa:**
En kind, kube-proxy puede interferir con el modo `kubeProxyReplacement=true` de Cilium si no se eliminó correctamente el DaemonSet de kube-proxy.

**Solución:**

```bash
# Verificar si kube-proxy sigue activo
kubectl get ds -n kube-system kube-proxy

# Si existe, eliminarlo (Cilium lo reemplaza)
kubectl delete ds kube-proxy -n kube-system

# Limpiar las reglas iptables residuales en cada nodo
for node in $(kubectl get nodes -o name); do
  NODE_NAME=$(echo $node | cut -d'/' -f2)
  docker exec $NODE_NAME bash -c "iptables-save | grep -i kube-proxy | wc -l"
done

# Reiniciar los pods de Cilium para que regeneren las reglas
kubectl rollout restart daemonset cilium -n kube-system
kubectl wait --for=condition=Ready pods -l k8s-app=cilium -n kube-system --timeout=60s

# Re-ejecutar validación
cilium status
```

---

## Limpieza

> **IMPORTANTE:** No elimines el clúster `lab-calico`. Se usará en los labs 02-10. Solo elimina el clúster `lab-cilium` si necesitas liberar recursos.

Para liberar recursos del clúster Cilium (opcional, solo si no se necesita más):

```bash
# Eliminar clúster Cilium (opcional)
kind delete cluster --name lab-cilium
```

Para limpiar solo los recursos de prueba manteniendo ambos clústeres:

```bash
# Limpiar namespace de prueba en Cilium
kubectl delete namespace network-test network-isolated --context kind-lab-cilium --ignore-not-found

# Limpiar NetworkPolicies en Calico (si se desea resetear para el siguiente lab)
# kubectl delete networkpolicies --all -n network-test --context kind-lab-calico
```

Asegúrate de que el contexto final sea el correcto:

```bash
kubectl config use-context kind-lab-calico
```

---

## Resumen

En este laboratorio has completado las siguientes tareas:

| Tarea | Clúster | CNI | Estado |
|-------|---------|-----|--------|
| Creación de clúster kind multi-nodo | lab-calico | — | ✓ |
| Instalación CNI con IPPool personalizado | lab-calico | Calico 3.28.0 | ✓ |
| Creación de clúster kind alternativo | lab-cilium | — | ✓ |
| Instalación CNI basado en eBPF | lab-cilium | Cilium 1.15.6 | ✓ |
| Validación de conectividad pod-to-pod | Ambos | Ambos | ✓ |
| Medición de throughput con iperf3 | Ambos | Ambos | ✓ |
| NetworkPolicy deny-all | Ambos | Ambos | ✓ |
| NetworkPolicy allow-selective | Ambos | Ambos | ✓ |

### Comparativa Clave

| Aspecto | Calico | Cilium |
|---------|--------|--------|
| **Modelo de datos** | BGP / VXLAN | eBPF |
| **IPAM** | Calico IPAM (blockSize configurable) | Kubernetes IPAM |
| **NetworkPolicy** | L3/L4 estándar + extensiones Calico | L3/L4/L7 (con CiliumNetworkPolicy) |
| **Observabilidad** | Limitada (requiere herramientas externas) | Hubble (integrada) |
| **Rendimiento** | Excelente con BGP nativo | Superior con eBPF bypass |
| **Complejidad operativa** | Media | Media-Alta |

### Recursos Adicionales

- [Documentación de Calico — IPPool Reference](https://docs.tigera.io/calico/latest/reference/resources/ippool)
- [Documentación de Cilium — Getting Started with kind](https://docs.cilium.io/en/v1.15/gettingstarted/k8s-install-default/)
- [Kubernetes NetworkPolicy API](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kind — Configuración de red avanzada](https://kind.sigs.k8s.io/docs/user/configuration/#networking)
