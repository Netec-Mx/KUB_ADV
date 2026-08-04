# Práctica 3 — Crear políticas de scheduling y extender comportamiento del scheduler

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Descripción General

En este laboratorio se implementarán políticas avanzadas de scheduling sobre el clúster `lab-calico`, incluyendo Node Affinity, Pod Anti-Affinity, Taints/Tolerations, TopologySpreadConstraints y PriorityClasses con preemption. Además, se desplegará un segundo scheduler personalizado (`custom-scheduler`) utilizando el framework de scheduling de Kubernetes con una configuración de scoring específica. El resultado será un clúster con control granular sobre la distribución de workloads y capacidad de priorización de cargas críticas.

## Objetivos de Aprendizaje

- [ ] Implementar Node Affinity, Pod Affinity y Pod Anti-Affinity para controlar la distribución de pods entre nodos
- [ ] Configurar Taints en nodos workers y Tolerations en pods para dedicar nodos por tipo de workload
- [ ] Crear y desplegar un segundo scheduler personalizado `custom-scheduler` con KubeSchedulerConfiguration
- [ ] Implementar TopologySpreadConstraints para distribución balanceada entre zonas simuladas
- [ ] Configurar PriorityClasses y demostrar preemption de pods batch por pods críticos

## Prerrequisitos

### Conocimiento requerido

- Familiaridad con el ciclo de scheduling de Kubernetes (filtrado y puntuación)
- Comprensión de labels, selectors y annotations en Kubernetes
- Conocimiento básico de RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
- Experiencia con manifiestos YAML de Deployments y Pods

### Acceso requerido

- Lab 01 completado: clúster `lab-calico` operativo con 1 control-plane + 2 workers
- Lab 02 completado: namespace `webapp` existente
- Docker registry local operativo en `localhost:5000`
- Contexto kubectl configurado: `kind-lab-calico`

## Entorno del Laboratorio

### Software utilizado

| Componente | Versión | Propósito |
|------------|---------|-----------|
| Kubernetes (kind) | 1.30.2 | Clúster de trabajo |
| kube-scheduler | v1.30.2 | Imagen para scheduler personalizado |
| kubectl | 1.30.2 | Gestión del clúster |
| kind | 0.23.0 | Infraestructura de clúster |

### Preparación del directorio de trabajo

```bash
mkdir -p ~/k8s-labs/lab03
cd ~/k8s-labs/lab03
```

### Verificación del clúster

```bash
# Cambiar al contexto correcto
kubectl cluster-info --context kind-lab-calico

# Verificar nodos disponibles
kubectl get nodes -o wide
```

**Salida esperada:**

```
NAME                       STATUS   ROLES           AGE   VERSION
lab-calico-control-plane   Ready    control-plane   ...   v1.30.2
lab-calico-worker          Ready    <none>          ...   v1.30.2
lab-calico-worker2         Ready    <none>          ...   v1.30.2
```

---

## Paso 1: Etiquetar nodos con zonas de disponibilidad y tipo de hardware

**Objetivo:** Añadir labels a los nodos workers para simular zonas de disponibilidad (`zone-a`, `zone-b`) y tipos de hardware (`compute`, `memory`).

### Instrucciones

1. Etiquetar el primer worker como `zone-a` con tipo `compute`:

```bash
kubectl label node lab-calico-worker \
  topology.kubernetes.io/zone=zone-a \
  node-type=compute \
  --overwrite
```

2. Etiquetar el segundo worker como `zone-b` con tipo `memory`:

```bash
kubectl label node lab-calico-worker2 \
  topology.kubernetes.io/zone=zone-b \
  node-type=memory \
  --overwrite
```

3. Verificar las etiquetas aplicadas:

```bash
kubectl get nodes -L topology.kubernetes.io/zone,node-type
```

**Salida esperada:**

```
NAME                       STATUS   ROLES           AGE   VERSION   ZONE     NODE-TYPE
lab-calico-control-plane   Ready    control-plane   ...   v1.30.2            
lab-calico-worker          Ready    <none>          ...   v1.30.2   zone-a   compute
lab-calico-worker2         Ready    <none>          ...   v1.30.2   zone-b   memory
```

### Verificación

```bash
kubectl get node lab-calico-worker -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
# Debe mostrar: zone-a

kubectl get node lab-calico-worker2 -o jsonpath='{.metadata.labels.node-type}'
# Debe mostrar: memory
```

---

## Paso 2: Configurar Taints en nodos workers

**Objetivo:** Aplicar taints a los nodos para dedicar `lab-calico-worker` a workloads de tipo `compute` y `lab-calico-worker2` a workloads de tipo `memory`.

### Instrucciones

1. Aplicar taint al worker de compute:

```bash
kubectl taint nodes lab-calico-worker workload-type=compute:NoSchedule
```

2. Aplicar taint al worker de memory:

```bash
kubectl taint nodes lab-calico-worker2 workload-type=memory:NoSchedule
```

3. Verificar los taints:

```bash
kubectl describe node lab-calico-worker | grep -A 3 "Taints:"
kubectl describe node lab-calico-worker2 | grep -A 3 "Taints:"
```

**Salida esperada:**

```
Taints:             workload-type=compute:NoSchedule
---
Taints:             workload-type=memory:NoSchedule
```

### Verificación

```bash
# Crear un pod sin toleration para confirmar que queda Pending
kubectl run taint-test --image=nginx:1.26 --restart=Never -n default
sleep 5
kubectl get pod taint-test -n default -o wide
```

El pod debe quedar en estado `Pending` porque no tiene tolerations para ningún worker.

```bash
# Limpiar pod de prueba
kubectl delete pod taint-test -n default --force 2>/dev/null
```

---

## Paso 3: Desplegar aplicación con Node Affinity y Tolerations

**Objetivo:** Crear un Deployment que use Node Affinity para seleccionar nodos `compute` y Tolerations para superar el taint correspondiente.

### Instrucciones

1. Crear el manifiesto del Deployment:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-compute-affinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-compute
  namespace: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp-compute
  template:
    metadata:
      labels:
        app: webapp-compute
    spec:
      tolerations:
        - key: workload-type
          operator: Equal
          value: compute
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-type
                    operator: In
                    values:
                      - compute
      containers:
        - name: nginx
          image: nginx:1.26
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          ports:
            - containerPort: 80
EOF
```

2. Aplicar el manifiesto:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-compute-affinity.yaml
```

3. Verificar que ambas réplicas se ejecutan en `lab-calico-worker`:

```bash
kubectl get pods -n webapp -l app=webapp-compute -o wide
```

**Salida esperada:**

```
NAME                              READY   STATUS    ...   NODE                 
webapp-compute-xxxxxxx-xxxxx      1/1     Running   ...   lab-calico-worker
webapp-compute-xxxxxxx-yyyyy      1/1     Running   ...   lab-calico-worker
```

### Verificación

```bash
# Confirmar que todos los pods están en el nodo compute
NODES=$(kubectl get pods -n webapp -l app=webapp-compute -o jsonpath='{.items[*].spec.nodeName}')
echo "$NODES"
# Debe mostrar solo: lab-calico-worker lab-calico-worker
```

---

## Paso 4: Implementar Pod Anti-Affinity para distribución entre zonas

**Objetivo:** Desplegar una aplicación con Pod Anti-Affinity que garantice que las réplicas se distribuyan en diferentes zonas de disponibilidad, combinado con tolerations para ambos tipos de nodo.

### Instrucciones

1. Crear el manifiesto:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-antiaffinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-distributed
  namespace: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp-distributed
  template:
    metadata:
      labels:
        app: webapp-distributed
    spec:
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - webapp-distributed
              topologyKey: topology.kubernetes.io/zone
      containers:
        - name: nginx
          image: nginx:1.26
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
EOF
```

2. Aplicar:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-antiaffinity.yaml
```

3. Esperar a que los pods estén Running:

```bash
kubectl rollout status deployment/webapp-distributed -n webapp --timeout=60s
```

4. Verificar distribución entre zonas:

```bash
kubectl get pods -n webapp -l app=webapp-distributed -o wide
```

**Salida esperada:**

Las dos réplicas deben estar en nodos diferentes (uno en `lab-calico-worker` / zone-a y otro en `lab-calico-worker2` / zone-b).

### Verificación

```bash
# Obtener los nodos donde se ejecutan los pods
kubectl get pods -n webapp -l app=webapp-distributed \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l
# Debe mostrar: 2 (dos nodos distintos)
```

---

## Paso 5: Implementar TopologySpreadConstraints

**Objetivo:** Crear un Deployment con `topologySpreadConstraints` para distribución balanceada entre zonas con un `maxSkew` de 1.

### Instrucciones

1. Crear el manifiesto:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-topology-spread.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-spread
  namespace: webapp
spec:
  replicas: 4
  selector:
    matchLabels:
      app: webapp-spread
  template:
    metadata:
      labels:
        app: webapp-spread
    spec:
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: webapp-spread
      containers:
        - name: nginx
          image: nginx:1.26
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
EOF
```

2. Aplicar:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-topology-spread.yaml
```

3. Esperar al rollout:

```bash
kubectl rollout status deployment/webapp-spread -n webapp --timeout=60s
```

4. Verificar distribución:

```bash
kubectl get pods -n webapp -l app=webapp-spread -o wide \
  --sort-by='.spec.nodeName'
```

**Salida esperada:**

Con 4 réplicas y `maxSkew: 1`, se deben distribuir 2 pods en cada zona (2 en `lab-calico-worker` y 2 en `lab-calico-worker2`).

### Verificación

```bash
# Contar pods por nodo
kubectl get pods -n webapp -l app=webapp-spread \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
```

Debe mostrar 2 pods en cada worker.

---

## Paso 6: Crear PriorityClasses

**Objetivo:** Definir tres PriorityClasses (`critical-priority`, `high-priority`, `batch-priority`) para gestión de prioridades y preemption.

### Instrucciones

1. Crear el manifiesto de PriorityClasses:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/priority-classes.yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-priority
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Prioridad para workloads críticos de producción"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 100000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Prioridad alta para servicios importantes"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-priority
value: 1000
globalDefault: false
preemptionPolicy: Never
description: "Prioridad baja para trabajos batch - sin preemption"
EOF
```

2. Aplicar:

```bash
kubectl apply -f ~/k8s-labs/lab03/priority-classes.yaml
```

3. Verificar:

```bash
kubectl get priorityclasses | grep -E "critical|high|batch"
```

**Salida esperada:**

```
batch-priority      1000       false   Never                 ...
critical-priority   1000000    false   PreemptLowerPriority  ...
high-priority       100000     false   PreemptLowerPriority  ...
```

### Verificación

```bash
kubectl get priorityclass critical-priority -o jsonpath='{.value}'
# Debe mostrar: 1000000

kubectl get priorityclass batch-priority -o jsonpath='{.preemptionPolicy}'
# Debe mostrar: Never
```

---

## Paso 7: Simular preemption con PriorityClasses

**Objetivo:** Desplegar pods batch que consuman recursos significativos y luego pods críticos que los desplacen mediante preemption.

### Instrucciones

1. Crear pods batch que consuman recursos en ambos workers:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-batch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-jobs
  namespace: webapp
spec:
  replicas: 6
  selector:
    matchLabels:
      app: batch-jobs
  template:
    metadata:
      labels:
        app: batch-jobs
    spec:
      priorityClassName: batch-priority
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      containers:
        - name: stress
          image: nginx:1.26
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 256Mi
          command: ["sleep", "3600"]
EOF
```

2. Aplicar los pods batch:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-batch.yaml
kubectl rollout status deployment/batch-jobs -n webapp --timeout=90s
```

3. Verificar que los pods batch están Running y consumiendo recursos:

```bash
kubectl get pods -n webapp -l app=batch-jobs -o wide
kubectl top nodes 2>/dev/null || echo "Metrics server puede no estar disponible"
```

4. Crear pods críticos que requieran preemption:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-critical.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: critical-service
  namespace: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: critical-service
  template:
    metadata:
      labels:
        app: critical-service
    spec:
      priorityClassName: critical-priority
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      containers:
        - name: critical
          image: nginx:1.26
          resources:
            requests:
              cpu: "1"
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 512Mi
          command: ["sleep", "3600"]
EOF
```

5. Aplicar los pods críticos:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-critical.yaml
```

6. Esperar y observar la preemption:

```bash
sleep 15
kubectl get pods -n webapp -l app=batch-jobs -o wide
kubectl get pods -n webapp -l app=critical-service -o wide
```

**Salida esperada:**

Los pods `critical-service` deben estar en estado `Running`. Algunos pods `batch-jobs` pueden haber sido desplazados (terminados y recreados en estado `Pending` si no hay capacidad restante).

7. Verificar eventos de preemption:

```bash
kubectl get events -n webapp --sort-by='.lastTimestamp' | grep -i "preempt\|evict" | tail -5
```

### Verificación

```bash
# Los pods críticos deben estar Running
kubectl get pods -n webapp -l app=critical-service \
  -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}'
# Debe mostrar: Running Running
```

---

## Paso 8: Crear y desplegar el Custom Scheduler

**Objetivo:** Desplegar un segundo scheduler `custom-scheduler` en `kube-system` usando la imagen oficial de kube-scheduler con una KubeSchedulerConfiguration personalizada que priorice la estrategia `MostAllocated`.

### Instrucciones

1. Crear el ServiceAccount y los permisos RBAC necesarios:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/custom-scheduler-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: custom-scheduler-sa
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: custom-scheduler-as-kube-scheduler
subjects:
  - kind: ServiceAccount
    name: custom-scheduler-sa
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: system:kube-scheduler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: custom-scheduler-as-volume-scheduler
subjects:
  - kind: ServiceAccount
    name: custom-scheduler-sa
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: system:volume-scheduler
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: custom-scheduler-extension-apiserver-authentication-reader
  namespace: kube-system
subjects:
  - kind: ServiceAccount
    name: custom-scheduler-sa
    namespace: kube-system
roleRef:
  kind: Role
  name: extension-apiserver-authentication-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

2. Aplicar RBAC:

```bash
kubectl apply -f ~/k8s-labs/lab03/custom-scheduler-rbac.yaml
```

3. Crear el ConfigMap con la configuración del scheduler:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/custom-scheduler-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-scheduler-config
  namespace: kube-system
data:
  config.yaml: |
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    leaderElection:
      leaderElect: true
      resourceNamespace: kube-system
      resourceName: custom-scheduler
    profiles:
      - schedulerName: custom-scheduler
        plugins:
          score:
            disabled:
              - name: NodeResourcesBalancedAllocation
            enabled:
              - name: NodeResourcesFit
                weight: 3
              - name: NodeAffinity
                weight: 2
              - name: InterPodAffinity
                weight: 2
        pluginConfig:
          - name: NodeResourcesFit
            args:
              scoringStrategy:
                type: MostAllocated
                resources:
                  - name: cpu
                    weight: 2
                  - name: memory
                    weight: 1
EOF
```

4. Aplicar el ConfigMap:

```bash
kubectl apply -f ~/k8s-labs/lab03/custom-scheduler-config.yaml
```

5. Crear el Deployment del custom scheduler:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/custom-scheduler-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-scheduler
  namespace: kube-system
  labels:
    component: custom-scheduler
spec:
  replicas: 1
  selector:
    matchLabels:
      component: custom-scheduler
  template:
    metadata:
      labels:
        component: custom-scheduler
    spec:
      serviceAccountName: custom-scheduler-sa
      containers:
        - name: kube-scheduler
          image: registry.k8s.io/kube-scheduler:v1.30.2
          command:
            - kube-scheduler
            - --config=/etc/kubernetes/config.yaml
            - --leader-elect=true
            - --leader-elect-resource-name=custom-scheduler
            - --leader-elect-resource-namespace=kube-system
            - --v=2
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /etc/kubernetes
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 10259
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 10259
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: custom-scheduler-config
EOF
```

6. Desplegar el custom scheduler:

```bash
kubectl apply -f ~/k8s-labs/lab03/custom-scheduler-deployment.yaml
```

7. Esperar a que esté listo:

```bash
kubectl rollout status deployment/custom-scheduler -n kube-system --timeout=60s
```

**Salida esperada:**

```
deployment "custom-scheduler" successfully rolled out
```

8. Verificar los logs del scheduler:

```bash
kubectl logs -n kube-system -l component=custom-scheduler --tail=20
```

### Verificación

```bash
# El pod del scheduler debe estar Running
kubectl get pods -n kube-system -l component=custom-scheduler
# Verificar que el scheduler está registrado observando sus logs
kubectl logs -n kube-system -l component=custom-scheduler | grep -i "starting\|leader"
```

---

## Paso 9: Desplegar pods usando el Custom Scheduler

**Objetivo:** Crear pods que utilicen `custom-scheduler` mediante el campo `schedulerName` y verificar que son programados por el scheduler personalizado.

### Instrucciones

1. Crear un Deployment que use el custom scheduler:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-custom-scheduled.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-custom-scheduled
  namespace: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp-custom-scheduled
  template:
    metadata:
      labels:
        app: webapp-custom-scheduled
    spec:
      schedulerName: custom-scheduler
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:1.26
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          ports:
            - containerPort: 80
EOF
```

2. Aplicar:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-custom-scheduled.yaml
```

3. Esperar a que los pods estén Running:

```bash
kubectl rollout status deployment/webapp-custom-scheduled -n webapp --timeout=60s
```

4. Verificar que el custom scheduler asignó los pods:

```bash
kubectl get pods -n webapp -l app=webapp-custom-scheduled -o wide
```

5. Confirmar el scheduler utilizado:

```bash
kubectl get pods -n webapp -l app=webapp-custom-scheduled \
  -o jsonpath='{range .items[*]}{.metadata.name}: schedulerName={.spec.schedulerName}{"\n"}{end}'
```

**Salida esperada:**

```
webapp-custom-scheduled-xxxxx: schedulerName=custom-scheduler
webapp-custom-scheduled-yyyyy: schedulerName=custom-scheduler
```

6. Verificar en los eventos que el custom scheduler realizó el binding:

```bash
kubectl get events -n webapp --field-selector reason=Scheduled \
  --sort-by='.lastTimestamp' | grep "custom-scheduler"
```

**Salida esperada:**

```
...  Successfully assigned webapp/webapp-custom-scheduled-xxxxx to lab-calico-worker by custom-scheduler
```

### Verificación

```bash
# Dado que la estrategia es MostAllocated, los pods deberían preferir el nodo más cargado
# Verificar que los pods fueron programados exitosamente
RUNNING=$(kubectl get pods -n webapp -l app=webapp-custom-scheduled \
  --field-selector status.phase=Running --no-headers | wc -l)
echo "Pods Running con custom-scheduler: $RUNNING"
# Debe mostrar: 2
```

---

## Paso 10: Combinación completa — Pod Affinity con TopologySpread y Custom Scheduler

**Objetivo:** Crear un Deployment final que combine Pod Affinity (co-ubicar con `webapp-compute`), TopologySpreadConstraints y el custom scheduler para demostrar la extensibilidad completa.

### Instrucciones

1. Crear el manifiesto combinado:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/deploy-combined.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-combined
  namespace: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp-combined
  template:
    metadata:
      labels:
        app: webapp-combined
    spec:
      schedulerName: custom-scheduler
      priorityClassName: high-priority
      tolerations:
        - key: workload-type
          operator: Exists
          effect: NoSchedule
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: webapp-combined
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 50
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - webapp-compute
                topologyKey: kubernetes.io/hostname
      containers:
        - name: nginx
          image: nginx:1.26
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
EOF
```

2. Aplicar:

```bash
kubectl apply -f ~/k8s-labs/lab03/deploy-combined.yaml
```

3. Verificar:

```bash
kubectl rollout status deployment/webapp-combined -n webapp --timeout=60s
kubectl get pods -n webapp -l app=webapp-combined -o wide
```

4. Confirmar scheduler y prioridad:

```bash
kubectl get pods -n webapp -l app=webapp-combined \
  -o jsonpath='{range .items[*]}{.metadata.name}: scheduler={.spec.schedulerName}, priority={.spec.priority}{"\n"}{end}'
```

**Salida esperada:**

```
webapp-combined-xxxxx: scheduler=custom-scheduler, priority=100000
webapp-combined-yyyyy: scheduler=custom-scheduler, priority=100000
```

---

## Validación y Testing

Ejecutar el siguiente script de validación completa:

```bash
cat <<'EOF' > ~/k8s-labs/lab03/validate.sh
#!/bin/bash
set -e

echo "=== Validación Lab 03 ==="
PASS=0
FAIL=0

# Test 1: Labels de zona en nodos
echo -n "[1] Labels de zona en workers... "
ZONE_A=$(kubectl get node lab-calico-worker -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
ZONE_B=$(kubectl get node lab-calico-worker2 -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
if [ "$ZONE_A" = "zone-a" ] && [ "$ZONE_B" = "zone-b" ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (zone-a=$ZONE_A, zone-b=$ZONE_B)"; ((FAIL++))
fi

# Test 2: Labels de tipo de nodo
echo -n "[2] Labels node-type... "
TYPE_A=$(kubectl get node lab-calico-worker -o jsonpath='{.metadata.labels.node-type}')
TYPE_B=$(kubectl get node lab-calico-worker2 -o jsonpath='{.metadata.labels.node-type}')
if [ "$TYPE_A" = "compute" ] && [ "$TYPE_B" = "memory" ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL"; ((FAIL++))
fi

# Test 3: Taints aplicados
echo -n "[3] Taints en workers... "
TAINT1=$(kubectl get node lab-calico-worker -o jsonpath='{.spec.taints[?(@.key=="workload-type")].value}')
TAINT2=$(kubectl get node lab-calico-worker2 -o jsonpath='{.spec.taints[?(@.key=="workload-type")].value}')
if [ "$TAINT1" = "compute" ] && [ "$TAINT2" = "memory" ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL"; ((FAIL++))
fi

# Test 4: webapp-compute en nodo compute
echo -n "[4] webapp-compute en nodo compute... "
NODES=$(kubectl get pods -n webapp -l app=webapp-compute -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u)
if [ "$NODES" = "lab-calico-worker" ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (nodos: $NODES)"; ((FAIL++))
fi

# Test 5: webapp-distributed en zonas distintas
echo -n "[5] webapp-distributed en zonas distintas... "
UNIQUE_NODES=$(kubectl get pods -n webapp -l app=webapp-distributed -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)
if [ "$UNIQUE_NODES" -eq 2 ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (nodos únicos: $UNIQUE_NODES)"; ((FAIL++))
fi

# Test 6: TopologySpread balanceado
echo -n "[6] webapp-spread distribuido balanceado... "
COUNT_W1=$(kubectl get pods -n webapp -l app=webapp-spread -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | grep -c "lab-calico-worker$" || true)
COUNT_W2=$(kubectl get pods -n webapp -l app=webapp-spread -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | grep -c "lab-calico-worker2" || true)
SKEW=$((COUNT_W1 > COUNT_W2 ? COUNT_W1 - COUNT_W2 : COUNT_W2 - COUNT_W1))
if [ "$SKEW" -le 1 ]; then
  echo "PASS (w1=$COUNT_W1, w2=$COUNT_W2)"; ((PASS++))
else
  echo "FAIL (skew=$SKEW)"; ((FAIL++))
fi

# Test 7: PriorityClasses creadas
echo -n "[7] PriorityClasses existentes... "
PC_COUNT=$(kubectl get priorityclasses | grep -cE "critical-priority|high-priority|batch-priority")
if [ "$PC_COUNT" -eq 3 ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (encontradas: $PC_COUNT)"; ((FAIL++))
fi

# Test 8: Custom scheduler running
echo -n "[8] custom-scheduler operativo... "
CS_STATUS=$(kubectl get pods -n kube-system -l component=custom-scheduler -o jsonpath='{.items[0].status.phase}')
if [ "$CS_STATUS" = "Running" ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (status: $CS_STATUS)"; ((FAIL++))
fi

# Test 9: Pods usando custom-scheduler
echo -n "[9] Pods programados por custom-scheduler... "
CS_PODS=$(kubectl get pods -n webapp -l app=webapp-custom-scheduled --field-selector status.phase=Running --no-headers | wc -l)
if [ "$CS_PODS" -ge 2 ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (running: $CS_PODS)"; ((FAIL++))
fi

# Test 10: Critical service running
echo -n "[10] critical-service con preemption... "
CRIT=$(kubectl get pods -n webapp -l app=critical-service --field-selector status.phase=Running --no-headers | wc -l)
if [ "$CRIT" -ge 2 ]; then
  echo "PASS"; ((PASS++))
else
  echo "FAIL (running: $CRIT)"; ((FAIL++))
fi

echo ""
echo "=== Resultado: $PASS/10 tests pasados, $FAIL fallidos ==="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ Lab 03 completado exitosamente"
else
  echo "⚠️  Revisar los tests fallidos"
fi
EOF

chmod +x ~/k8s-labs/lab03/validate.sh
~/k8s-labs/lab03/validate.sh
```

---

## Troubleshooting

### Problema 1: Custom Scheduler en CrashLoopBackOff

**Síntomas:** El pod `custom-scheduler` en `kube-system` reinicia continuamente con estado `CrashLoopBackOff`. Los logs muestran errores de autenticación o permisos.

**Causa:** El ServiceAccount no tiene los ClusterRoleBindings necesarios, o el ConfigMap tiene un error de sintaxis en la KubeSchedulerConfiguration que impide que el scheduler arranque.

**Solución:**

```bash
# Revisar logs detallados
kubectl logs -n kube-system -l component=custom-scheduler --previous

# Verificar que el RBAC está aplicado correctamente
kubectl get clusterrolebinding custom-scheduler-as-kube-scheduler -o yaml

# Validar la configuración del ConfigMap
kubectl get configmap custom-scheduler-config -n kube-system -o jsonpath='{.data.config\.yaml}' | head -20

# Si hay error de sintaxis, corregir y reaplicar
kubectl apply -f ~/k8s-labs/lab03/custom-scheduler-config.yaml
kubectl rollout restart deployment/custom-scheduler -n kube-system
```

### Problema 2: Pods quedan en Pending por Taints sin Tolerations

**Síntomas:** Pods nuevos quedan indefinidamente en estado `Pending`. El evento muestra `0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane:}, 2 node(s) had untolerated taint {workload-type: ...}`.

**Causa:** Los pods no incluyen la sección `tolerations` para el taint `workload-type` aplicado a los workers. Como el control-plane también tiene un taint por defecto, ningún nodo es elegible.

**Solución:**

```bash
# Verificar los taints de todos los nodos
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'

# Añadir la toleration correcta al pod/deployment
# Para tolerar cualquier valor del taint workload-type:
# tolerations:
#   - key: workload-type
#     operator: Exists
#     effect: NoSchedule

# Verificar que el pod tiene la toleration
kubectl get pod <pod-name> -n webapp -o jsonpath='{.spec.tolerations}' | jq .

# Si necesitas remover un taint temporalmente para debug:
kubectl taint nodes lab-calico-worker workload-type=compute:NoSchedule-
# (Recuerda reaplicarlo después)
kubectl taint nodes lab-calico-worker workload-type=compute:NoSchedule
```

---

## Limpieza

> **Nota:** Los labels y taints en los nodos **persisten** para labs posteriores según la especificación. Solo se limpian los workloads de prueba.

```bash
# Eliminar deployments de prueba (mantener webapp original del Lab 02)
kubectl delete deployment webapp-compute -n webapp --ignore-not-found
kubectl delete deployment webapp-distributed -n webapp --ignore-not-found
kubectl delete deployment webapp-spread -n webapp --ignore-not-found
kubectl delete deployment batch-jobs -n webapp --ignore-not-found
kubectl delete deployment critical-service -n webapp --ignore-not-found
kubectl delete deployment webapp-custom-scheduled -n webapp --ignore-not-found
kubectl delete deployment webapp-combined -n webapp --ignore-not-found

# MANTENER: custom-scheduler, PriorityClasses, labels y taints (requeridos por labs posteriores)
echo "✅ Workloads de prueba eliminados"
echo "ℹ️  Se mantienen: custom-scheduler, PriorityClasses, labels de zona, taints de nodos"
```

Para una limpieza completa (solo si no se continuará con labs posteriores):

```bash
# Limpieza total (SOLO si no se necesita para otros labs)
# kubectl delete deployment custom-scheduler -n kube-system
# kubectl delete configmap custom-scheduler-config -n kube-system
# kubectl delete sa custom-scheduler-sa -n kube-system
# kubectl delete clusterrolebinding custom-scheduler-as-kube-scheduler
# kubectl delete clusterrolebinding custom-scheduler-as-volume-scheduler
# kubectl delete rolebinding custom-scheduler-extension-apiserver-authentication-reader -n kube-system
# kubectl delete priorityclass critical-priority high-priority batch-priority
# kubectl taint nodes lab-calico-worker workload-type=compute:NoSchedule-
# kubectl taint nodes lab-calico-worker2 workload-type=memory:NoSchedule-
# kubectl label node lab-calico-worker topology.kubernetes.io/zone- node-type-
# kubectl label node lab-calico-worker2 topology.kubernetes.io/zone- node-type-
```

---

## Resumen

En este laboratorio se implementaron las siguientes capacidades avanzadas de scheduling:

| Concepto | Implementación |
|----------|---------------|
| **Node Affinity** | Pods `webapp-compute` forzados a nodos con label `node-type=compute` |
| **Pod Anti-Affinity** | Pods `webapp-distributed` en zonas diferentes obligatoriamente |
| **Taints/Tolerations** | Nodos dedicados por tipo de workload con `NoSchedule` |
| **TopologySpreadConstraints** | Distribución balanceada con `maxSkew: 1` entre zonas |
| **PriorityClasses** | Tres niveles (1000000, 100000, 1000) con preemption configurable |
| **Preemption** | Pods críticos desplazan pods batch de baja prioridad |
| **Custom Scheduler** | Segundo scheduler con estrategia `MostAllocated` operativo |

### Puntos clave

- El campo `schedulerName` en la especificación del Pod determina qué scheduler lo procesa
- La estrategia `MostAllocated` empaqueta pods en menos nodos (útil para consolidación)
- `preemptionPolicy: Never` en PriorityClass evita que pods de esa clase desplacen a otros
- Los Taints con efecto `NoSchedule` requieren Tolerations explícitas; `operator: Exists` tolera cualquier valor
- TopologySpreadConstraints con `whenUnsatisfiable: DoNotSchedule` es estricto; `ScheduleAnyway` es best-effort

### Recursos adicionales

- [Kubernetes Scheduler Configuration Reference](https://kubernetes.io/docs/reference/scheduling/config/)
- [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Scheduler Plugins Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
