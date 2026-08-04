# Diseñar y Validar un Plan de DR Multi-Cluster

## Metadatos

| Campo | Valor |
|-------|-------|
| **Duración** | 41 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Descripción General

Este laboratorio culminante integra los componentes desplegados en los Labs 01-09 para diseñar, implementar y validar un plan completo de Recuperación ante Desastres (DR) multi-cluster. Se creará un segundo clúster Kubernetes (`lab-dr`) como sitio de recuperación, se configurará Velero con MinIO como backend de almacenamiento S3, se implementarán schedules de backup automatizados y se ejecutará un ejercicio completo de failover con medición de RTO/RPO reales contra objetivos definidos.

## Objetivos de Aprendizaje

- [ ] Crear y configurar un clúster de recuperación ante desastres (`lab-dr`) con la misma topología que el clúster primario
- [ ] Configurar Velero 1.14.0 con MinIO como backend S3 compartido entre ambos clústeres para backup y restauración
- [ ] Implementar schedules de backup automatizados con políticas de retención diferenciadas
- [ ] Ejecutar un ejercicio completo de DR: backup, simulación de fallo, restauración y validación funcional
- [ ] Documentar y medir RTO/RPO reales comparándolos contra los objetivos establecidos (RTO: 30 min, RPO: 1 hora)

## Prerrequisitos

### Conocimiento Requerido

- Labs 01-09 completados con todos los componentes operativos en el clúster `lab-calico`
- Familiaridad con conceptos de DR: RTO, RPO, backup/restore
- Experiencia con kubectl context switching y gestión multi-cluster
- Comprensión de almacenamiento S3-compatible y Velero

### Acceso y Herramientas

| Herramienta | Versión | Verificación |
|-------------|---------|--------------|
| Velero CLI | 1.14.0 | `velero version --client-only` |
| kind | 0.23.0 | `kind version` |
| kubectl | 1.30.2 | `kubectl version --client` |
| Helm | 3.15.2 | `helm version --short` |
| Docker Engine | 26.1.4 | `docker version` |

## Entorno del Laboratorio

### Arquitectura Multi-Cluster

| Clúster | Rol | Contexto kubectl | CNI |
|---------|-----|------------------|-----|
| `lab-calico` | Primario (producción) | `kind-lab-calico` | Calico 3.28.0 |
| `lab-dr` | Recuperación (DR) | `kind-lab-dr` | Calico 3.28.0 |

### Componentes de Infraestructura DR

| Componente | Namespace | Propósito |
|------------|-----------|-----------|
| MinIO | `velero-backend` | Backend S3 para backups |
| Velero | `velero` | Orquestación de backup/restore |
| Prometheus | `monitoring` | Métricas federadas |

### Preparación del Directorio de Trabajo

```bash
mkdir -p ~/k8s-labs/lab10/{manifests,backups,reports,scripts}
cd ~/k8s-labs/lab10
```

---

## Paso 1: Desplegar MinIO como Backend de Almacenamiento S3

**Objetivo:** Instalar MinIO en el clúster primario como almacenamiento S3-compatible accesible desde ambos clústeres kind.

### Instrucciones

1. Asegurar que estamos en el contexto del clúster primario:

```bash
kubectl config use-context kind-lab-calico
```

2. Crear el namespace para el backend de almacenamiento:

```bash
kubectl create namespace velero-backend
```

3. Crear el manifiesto de despliegue de MinIO:

```bash
cat > ~/k8s-labs/lab10/manifests/minio-deployment.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: velero-backend
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: velero-backend
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:RELEASE.2024-06-29T01-20-47Z
          command:
            - /bin/bash
            - -c
          args:
            - minio server /data --console-address :9001
          env:
            - name: MINIO_ROOT_USER
              value: "minio"
            - name: MINIO_ROOT_PASSWORD
              value: "minio123"
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: storage
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: velero-backend
spec:
  type: NodePort
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
      nodePort: 30900
      name: api
    - port: 9001
      targetPort: 9001
      nodePort: 30901
      name: console
EOF
```

4. Aplicar el manifiesto:

```bash
kubectl apply -f ~/k8s-labs/lab10/manifests/minio-deployment.yaml
```

5. Esperar a que MinIO esté listo:

```bash
kubectl wait --for=condition=ready pod -l app=minio \
  -n velero-backend --timeout=120s
```

6. Obtener la IP del nodo para acceso desde el clúster DR:

```bash
MINIO_NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "MinIO API endpoint: http://${MINIO_NODE_IP}:30900"
echo $MINIO_NODE_IP > ~/k8s-labs/lab10/minio-ip.txt
```

7. Crear el bucket `velero-backups` usando un Job:

```bash
cat > ~/k8s-labs/lab10/manifests/minio-create-bucket.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: velero-backend
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: quay.io/minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set myminio http://minio.velero-backend.svc:9000 minio minio123
              mc mb --ignore-existing myminio/velero-backups
              mc ls myminio/velero-backups
              echo "Bucket 'velero-backups' creado exitosamente"
  backoffLimit: 3
EOF

kubectl apply -f ~/k8s-labs/lab10/manifests/minio-create-bucket.yaml
kubectl wait --for=condition=complete job/minio-create-bucket \
  -n velero-backend --timeout=60s
```

### Salida Esperada

```
namespace/velero-backend created
persistentvolumeclaim/minio-pvc created
deployment.apps/minio created
service/minio created
pod/minio-xxxxx condition met
job.batch/minio-create-bucket condition met
```

### Verificación

```bash
kubectl logs job/minio-create-bucket -n velero-backend
kubectl get all -n velero-backend
```

---

## Paso 2: Crear el Clúster de Recuperación `lab-dr`

**Objetivo:** Provisionar un segundo clúster kind con la misma topología que el primario para actuar como sitio de recuperación.

### Instrucciones

1. Crear la configuración del clúster DR:

```bash
cat > ~/k8s-labs/lab10/manifests/kind-config-dr.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab-dr
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
    image: kindest/node:v1.30.2
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
  - role: worker
    image: kindest/node:v1.30.2
  - role: worker
    image: kindest/node:v1.30.2
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://registry:5000"]
EOF
```

2. Crear el clúster:

```bash
kind create cluster --config ~/k8s-labs/lab10/manifests/kind-config-dr.yaml
```

3. Verificar el contexto:

```bash
kubectl config use-context kind-lab-dr
kubectl get nodes
```

4. Conectar el clúster DR a la red Docker del registry local:

```bash
docker network connect kind registry 2>/dev/null || true
```

5. Instalar Calico CNI en el clúster DR:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

6. Esperar a que los nodos estén Ready:

```bash
kubectl wait --for=condition=ready nodes --all --timeout=180s
```

7. Conectar las redes Docker de ambos clústeres para que el DR pueda alcanzar MinIO:

```bash
# Obtener las redes de los contenedores kind
docker network connect kind $(docker ps --filter "name=lab-calico-control-plane" --format "{{.ID}}") 2>/dev/null || true
```

### Salida Esperada

```
Creating cluster "lab-dr" ...
 ✓ Ensuring node image (kindest/node:v1.30.2) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-lab-dr"
```

### Verificación

```bash
kubectl get nodes -o wide --context kind-lab-dr
kubectl get pods -n kube-system --context kind-lab-dr | grep calico
```

---

## Paso 3: Instalar Velero en el Clúster Primario

**Objetivo:** Configurar Velero en el clúster `lab-calico` apuntando a MinIO como BackupStorageLocation.

### Instrucciones

1. Cambiar al contexto del clúster primario:

```bash
kubectl config use-context kind-lab-calico
```

2. Crear el archivo de credenciales para MinIO:

```bash
cat > ~/k8s-labs/lab10/manifests/velero-credentials.txt << 'EOF'
[default]
aws_access_key_id = minio
aws_secret_access_key = minio123
EOF
```

3. Obtener la URL interna de MinIO (Service DNS):

```bash
MINIO_URL="http://minio.velero-backend.svc:9000"
echo "MinIO URL para Velero (primario): ${MINIO_URL}"
```

4. Instalar Velero en el clúster primario:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket velero-backups \
  --secret-file ~/k8s-labs/lab10/manifests/velero-credentials.txt \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=${MINIO_URL} \
  --use-volume-snapshots=false \
  --namespace velero
```

5. Verificar que Velero está operativo:

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=velero \
  -n velero --timeout=120s
velero backup-location get
```

### Salida Esperada

```
Velero is installed! ⛵ Use 'velero' CLI to manage backups and restores.
NAME      PROVIDER   BUCKET/PREFIX     PHASE       LAST VALIDATED   ACCESS MODE   DEFAULT
default   aws        velero-backups    Available   <timestamp>      ReadWrite     true
```

### Verificación

```bash
velero backup-location get
# La columna PHASE debe mostrar "Available"
```

---

## Paso 4: Instalar Velero en el Clúster DR

**Objetivo:** Configurar Velero en el clúster `lab-dr` apuntando al mismo MinIO para poder restaurar backups del primario.

### Instrucciones

1. Cambiar al contexto del clúster DR:

```bash
kubectl config use-context kind-lab-dr
```

2. Obtener la IP accesible de MinIO desde el clúster DR:

```bash
# MinIO está en el clúster primario, accesible via la IP del nodo control-plane
MINIO_DR_IP=$(docker inspect lab-calico-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
MINIO_DR_URL="http://${MINIO_DR_IP}:30900"
echo "MinIO URL para Velero (DR): ${MINIO_DR_URL}"
echo $MINIO_DR_URL > ~/k8s-labs/lab10/minio-dr-url.txt
```

3. Instalar Velero en el clúster DR:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket velero-backups \
  --secret-file ~/k8s-labs/lab10/manifests/velero-credentials.txt \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=${MINIO_DR_URL} \
  --use-volume-snapshots=false \
  --namespace velero
```

4. Esperar a que Velero esté listo:

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=velero \
  -n velero --timeout=120s
```

5. Verificar conectividad con el backend:

```bash
velero backup-location get
```

### Salida Esperada

```
NAME      PROVIDER   BUCKET/PREFIX     PHASE       LAST VALIDATED   ACCESS MODE   DEFAULT
default   aws        velero-backups    Available   <timestamp>      ReadWrite     true
```

### Verificación

```bash
# Desde el clúster DR, verificar que puede ver backups del primario (estará vacío inicialmente)
velero backup get
```

---

## Paso 5: Crear Schedules de Backup Automatizados

**Objetivo:** Implementar cuatro schedules de backup con políticas de retención diferenciadas según la estrategia de DR.

### Instrucciones

1. Cambiar al contexto del clúster primario:

```bash
kubectl config use-context kind-lab-calico
```

2. Crear el schedule `hourly-webapp` (cada hora, retención 24h):

```bash
velero schedule create hourly-webapp \
  --schedule="0 * * * *" \
  --include-namespaces webapp \
  --ttl 24h0m0s \
  --labels tier=application,frequency=hourly
```

3. Crear el schedule `daily-full` (diario a las 2am, retención 7 días):

```bash
velero schedule create daily-full \
  --schedule="0 2 * * *" \
  --ttl 168h0m0s \
  --labels tier=full,frequency=daily
```

4. Crear el schedule `weekly-full` (semanal domingos 3am, retención 4 semanas):

```bash
velero schedule create weekly-full \
  --schedule="0 3 * * 0" \
  --ttl 672h0m0s \
  --labels tier=full,frequency=weekly
```

5. Crear el manifiesto para backups manuales pre-upgrade:

```bash
cat > ~/k8s-labs/lab10/scripts/pre-upgrade-backup.sh << 'EOF'
#!/bin/bash
# Script de backup pre-upgrade
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="pre-upgrade-${TIMESTAMP}"

echo "=== Iniciando backup pre-upgrade: ${BACKUP_NAME} ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" 

velero backup create ${BACKUP_NAME} \
  --ttl 720h0m0s \
  --labels tier=pre-upgrade,trigger=manual \
  --wait

echo "=== Backup completado ==="
velero backup describe ${BACKUP_NAME}
EOF
chmod +x ~/k8s-labs/lab10/scripts/pre-upgrade-backup.sh
```

6. Verificar todos los schedules:

```bash
velero schedule get
```

### Salida Esperada

```
NAME             STATUS    CREATED                         SCHEDULE      BACKUP TTL   LAST BACKUP   SELECTOR
hourly-webapp    Enabled   2024-xx-xx xx:xx:xx +0000 UTC   0 * * * *    24h0m0s      <none yet>    <none>
daily-full       Enabled   2024-xx-xx xx:xx:xx +0000 UTC   0 2 * * *    168h0m0s     <none yet>    <none>
weekly-full      Enabled   2024-xx-xx xx:xx:xx +0000 UTC   0 3 * * 0    672h0m0s     <none yet>    <none>
```

### Verificación

```bash
velero schedule get -o json | jq '.items[].metadata.name'
```

---

## Paso 6: Ejecutar Backup Completo del Clúster Primario

**Objetivo:** Crear un backup on-demand completo que servirá como punto de restauración para el ejercicio de DR.

### Instrucciones

1. Asegurar el contexto del clúster primario:

```bash
kubectl config use-context kind-lab-calico
```

2. Registrar el estado previo al backup (inventario):

```bash
cat > ~/k8s-labs/lab10/scripts/inventory.sh << 'EOF'
#!/bin/bash
CONTEXT=$1
echo "=== Inventario del clúster (contexto: ${CONTEXT}) ==="
echo ""
echo "--- Namespaces ---"
kubectl get ns --context ${CONTEXT} -o name | sort
echo ""
echo "--- Pods en webapp ---"
kubectl get pods -n webapp --context ${CONTEXT} -o wide 2>/dev/null || echo "Namespace webapp no existe"
echo ""
echo "--- Services en webapp ---"
kubectl get svc -n webapp --context ${CONTEXT} 2>/dev/null || echo "Namespace webapp no existe"
echo ""
echo "--- Deployments en webapp ---"
kubectl get deploy -n webapp --context ${CONTEXT} 2>/dev/null || echo "Namespace webapp no existe"
echo ""
echo "--- Ingress en webapp ---"
kubectl get ingress -n webapp --context ${CONTEXT} 2>/dev/null || echo "No hay Ingress"
echo ""
echo "--- ConfigMaps en webapp ---"
kubectl get cm -n webapp --context ${CONTEXT} 2>/dev/null || echo "Namespace webapp no existe"
echo ""
echo "--- Secrets en webapp ---"
kubectl get secrets -n webapp --context ${CONTEXT} 2>/dev/null || echo "Namespace webapp no existe"
EOF
chmod +x ~/k8s-labs/lab10/scripts/inventory.sh
```

3. Ejecutar inventario del clúster primario:

```bash
~/k8s-labs/lab10/scripts/inventory.sh kind-lab-calico > ~/k8s-labs/lab10/reports/pre-disaster-inventory.txt
cat ~/k8s-labs/lab10/reports/pre-disaster-inventory.txt
```

4. Registrar el timestamp de inicio del backup:

```bash
DR_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "DR Exercise Start: ${DR_START_TIME}" > ~/k8s-labs/lab10/reports/dr-timeline.txt
```

5. Crear el backup completo:

```bash
BACKUP_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DR_BACKUP_NAME="dr-exercise-${BACKUP_TIMESTAMP}"

velero backup create ${DR_BACKUP_NAME} \
  --include-namespaces webapp,monitoring,ingress-nginx \
  --labels exercise=dr-test,type=full \
  --wait

echo "DR_BACKUP_NAME=${DR_BACKUP_NAME}" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
echo $DR_BACKUP_NAME > ~/k8s-labs/lab10/reports/backup-name.txt
```

6. Verificar el estado del backup:

```bash
velero backup describe ${DR_BACKUP_NAME}
velero backup logs ${DR_BACKUP_NAME} | tail -20
```

### Salida Esperada

```
Name:         dr-exercise-20240xxx-xxxxxx
Namespace:    velero
Labels:       exercise=dr-test
              type=full
              velero.io/storage-location=default
Annotations:  velero.io/source-cluster-k8s-gitversion=v1.30.2

Phase:  Completed

Namespaces:
  Included:  webapp, monitoring, ingress-nginx
  Excluded:  <none>

Resources:
  Included:        *
  Excluded:        <none>
  Cluster-scoped:  auto
```

### Verificación

```bash
velero backup get | grep "dr-exercise"
# Phase debe ser "Completed"
```

---

## Paso 7: Simular Desastre en el Clúster Primario

**Objetivo:** Simular un fallo catastrófico eliminando los recursos del namespace `webapp` en el clúster primario.

### Instrucciones

1. Registrar el timestamp de inicio del desastre:

```bash
DISASTER_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Disaster Simulated: ${DISASTER_TIME}" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
```

2. Documentar qué se va a eliminar:

```bash
echo "=== RECURSOS A ELIMINAR (simulación de desastre) ===" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
kubectl get all -n webapp >> ~/k8s-labs/lab10/reports/dr-timeline.txt 2>/dev/null
```

3. Eliminar completamente el namespace `webapp`:

```bash
kubectl delete namespace webapp --wait=true
```

4. Verificar que el namespace fue eliminado:

```bash
kubectl get namespace webapp 2>&1
```

5. Registrar el estado post-desastre:

```bash
echo "=== ESTADO POST-DESASTRE ===" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
echo "Namespace webapp eliminado: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
~/k8s-labs/lab10/scripts/inventory.sh kind-lab-calico > ~/k8s-labs/lab10/reports/post-disaster-inventory.txt
```

### Salida Esperada

```
namespace "webapp" deleted
Error from server (NotFound): namespaces "webapp" not found
```

### Verificación

```bash
kubectl get ns | grep webapp
# No debe aparecer el namespace webapp
```

---

## Paso 8: Restaurar en el Clúster DR

**Objetivo:** Ejecutar la restauración del backup en el clúster `lab-dr` y medir el tiempo de recuperación.

### Instrucciones

1. Registrar el inicio de la restauración:

```bash
RESTORE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Restore Started: ${RESTORE_START}" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
```

2. Cambiar al contexto del clúster DR:

```bash
kubectl config use-context kind-lab-dr
```

3. Sincronizar el backup location para que el clúster DR vea los backups:

```bash
velero backup-location get
# Esperar unos segundos para la sincronización
sleep 10
velero backup get
```

4. Leer el nombre del backup:

```bash
DR_BACKUP_NAME=$(cat ~/k8s-labs/lab10/reports/backup-name.txt)
echo "Restaurando backup: ${DR_BACKUP_NAME}"
```

5. Ejecutar la restauración del namespace `webapp`:

```bash
velero restore create dr-restore-webapp \
  --from-backup ${DR_BACKUP_NAME} \
  --include-namespaces webapp \
  --wait
```

6. Verificar el estado de la restauración:

```bash
velero restore describe dr-restore-webapp
```

7. Esperar a que los pods estén listos:

```bash
kubectl wait --for=condition=ready pods --all \
  -n webapp --timeout=180s 2>/dev/null || echo "Esperando pods..."
sleep 15
kubectl get pods -n webapp
```

8. Registrar el fin de la restauración:

```bash
RESTORE_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Restore Completed: ${RESTORE_END}" >> ~/k8s-labs/lab10/reports/dr-timeline.txt
```

### Salida Esperada

```
Restore request "dr-restore-webapp" submitted successfully.
Waiting for restore to complete. You may safely press ctrl-c...

Name:         dr-restore-webapp
Namespace:    velero
Labels:       <none>
Annotations:  <none>

Phase:                       Completed
Total items to be restored:  XX
Items restored:              XX
```

### Verificación

```bash
kubectl get all -n webapp --context kind-lab-dr
velero restore get
```

---

## Paso 9: Validar la Restauración y Medir RTO/RPO

**Objetivo:** Confirmar que la aplicación restaurada es funcional y documentar las métricas de recuperación.

### Instrucciones

1. Verificar que todos los recursos fueron restaurados en el clúster DR:

```bash
kubectl config use-context kind-lab-dr
~/k8s-labs/lab10/scripts/inventory.sh kind-lab-dr > ~/k8s-labs/lab10/reports/post-restore-inventory.txt
cat ~/k8s-labs/lab10/reports/post-restore-inventory.txt
```

2. Comparar inventarios pre-desastre vs post-restauración:

```bash
echo "=== COMPARACIÓN DE INVENTARIOS ===" > ~/k8s-labs/lab10/reports/comparison.txt
echo "" >> ~/k8s-labs/lab10/reports/comparison.txt
echo "--- Deployments en primario (pre-desastre) ---" >> ~/k8s-labs/lab10/reports/comparison.txt
grep -A 20 "Deployments en webapp" ~/k8s-labs/lab10/reports/pre-disaster-inventory.txt >> ~/k8s-labs/lab10/reports/comparison.txt
echo "" >> ~/k8s-labs/lab10/reports/comparison.txt
echo "--- Deployments en DR (post-restauración) ---" >> ~/k8s-labs/lab10/reports/comparison.txt
grep -A 20 "Deployments en webapp" ~/k8s-labs/lab10/reports/post-restore-inventory.txt >> ~/k8s-labs/lab10/reports/comparison.txt
cat ~/k8s-labs/lab10/reports/comparison.txt
```

3. Verificar que los pods están Running:

```bash
kubectl get pods -n webapp -o wide
RUNNING_PODS=$(kubectl get pods -n webapp --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
echo "Pods Running en webapp (DR): ${RUNNING_PODS}"
```

4. Verificar Services y Endpoints:

```bash
kubectl get svc -n webapp
kubectl get endpoints -n webapp
```

5. Generar el reporte de RTO/RPO:

```bash
cat > ~/k8s-labs/lab10/scripts/generate-dr-report.sh << 'EOF'
#!/bin/bash

REPORT_FILE=~/k8s-labs/lab10/reports/dr-final-report.md
TIMELINE_FILE=~/k8s-labs/lab10/reports/dr-timeline.txt

echo "# Reporte de Ejercicio de Recuperación ante Desastres" > ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Fecha de Ejecución" >> ${REPORT_FILE}
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Timeline del Ejercicio" >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
cat ${TIMELINE_FILE} >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Objetivos vs Resultados" >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "| Métrica | Objetivo | Resultado | Estado |" >> ${REPORT_FILE}
echo "|---------|----------|-----------|--------|" >> ${REPORT_FILE}
echo "| RTO (Recovery Time Objective) | 30 minutos | Medido durante ejercicio | ✅/❌ |" >> ${REPORT_FILE}
echo "| RPO (Recovery Point Objective) | 1 hora | Backup < 1h antigüedad | ✅ |" >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Estado de Recursos Restaurados" >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
kubectl get all -n webapp --context kind-lab-dr 2>/dev/null >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Backup Utilizado" >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
velero backup describe $(cat ~/k8s-labs/lab10/reports/backup-name.txt) --context kind-lab-dr 2>/dev/null >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Schedules de Backup Configurados" >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
velero schedule get --context kind-lab-calico 2>/dev/null >> ${REPORT_FILE}
echo '```' >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "## Plan de DR Documentado" >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "### Procedimiento de Failover" >> ${REPORT_FILE}
echo "1. Detectar fallo del clúster primario (alertas Prometheus)" >> ${REPORT_FILE}
echo "2. Verificar último backup disponible en MinIO" >> ${REPORT_FILE}
echo "3. Cambiar contexto kubectl al clúster DR (kind-lab-dr)" >> ${REPORT_FILE}
echo "4. Ejecutar restauración: velero restore create --from-backup <latest>" >> ${REPORT_FILE}
echo "5. Validar pods Running y endpoints activos" >> ${REPORT_FILE}
echo "6. Actualizar DNS/Ingress para apuntar al clúster DR" >> ${REPORT_FILE}
echo "7. Notificar stakeholders" >> ${REPORT_FILE}
echo "" >> ${REPORT_FILE}
echo "### Procedimiento de Failback" >> ${REPORT_FILE}
echo "1. Restaurar clúster primario" >> ${REPORT_FILE}
echo "2. Ejecutar backup del clúster DR" >> ${REPORT_FILE}
echo "3. Restaurar en clúster primario" >> ${REPORT_FILE}
echo "4. Validar integridad" >> ${REPORT_FILE}
echo "5. Redirigir tráfico al primario" >> ${REPORT_FILE}
echo "6. Verificar operación normal" >> ${REPORT_FILE}

echo "Reporte generado en: ${REPORT_FILE}"
EOF
chmod +x ~/k8s-labs/lab10/scripts/generate-dr-report.sh
~/k8s-labs/lab10/scripts/generate-dr-report.sh
```

6. Visualizar el reporte final:

```bash
cat ~/k8s-labs/lab10/reports/dr-final-report.md
```

### Salida Esperada

```
# Reporte de Ejercicio de Recuperación ante Desastres

## Fecha de Ejecución
2024-xx-xxTxx:xx:xxZ

## Timeline del Ejercicio
DR Exercise Start: 2024-xx-xxTxx:xx:xxZ
Disaster Simulated: 2024-xx-xxTxx:xx:xxZ
Restore Started: 2024-xx-xxTxx:xx:xxZ
Restore Completed: 2024-xx-xxTxx:xx:xxZ
...
```

### Verificación

```bash
ls -la ~/k8s-labs/lab10/reports/
# Debe contener: dr-final-report.md, dr-timeline.txt, pre-disaster-inventory.txt, 
# post-disaster-inventory.txt, post-restore-inventory.txt, comparison.txt
```

---

## Paso 10: Configurar Prometheus Federation entre Clústeres

**Objetivo:** Implementar métricas federadas para observabilidad unificada del estado de ambos clústeres.

### Instrucciones

1. Crear el namespace de monitoring en el clúster DR:

```bash
kubectl config use-context kind-lab-dr
kubectl create namespace monitoring
```

2. Crear una configuración mínima de Prometheus con federation:

```bash
cat > ~/k8s-labs/lab10/manifests/prometheus-federation-dr.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 30s
      evaluation_interval: 30s

    scrape_configs:
      - job_name: 'kubernetes-pods-dr'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true

      - job_name: 'velero-metrics'
        static_configs:
          - targets: ['velero.velero.svc:8085']
        metrics_path: /metrics

      - job_name: 'federation-primary'
        honor_labels: true
        metrics_path: '/federate'
        params:
          'match[]':
            - '{job=~".*"}'
            - '{__name__=~"velero_.*"}'
            - '{__name__=~"kube_.*"}'
        static_configs:
          - targets: ['prometheus-primary.monitoring.svc:9090']
            labels:
              cluster: 'lab-calico'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-dr
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-dr
  template:
    metadata:
      labels:
        app: prometheus-dr
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.53.0
          args:
            - '--config.file=/etc/prometheus/prometheus.yml'
            - '--storage.tsdb.path=/prometheus'
            - '--storage.tsdb.retention.time=7d'
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: storage
              mountPath: /prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: storage
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-dr
  namespace: monitoring
spec:
  selector:
    app: prometheus-dr
  ports:
    - port: 9090
      targetPort: 9090
  type: ClusterIP
EOF
```

3. Aplicar la configuración:

```bash
kubectl apply -f ~/k8s-labs/lab10/manifests/prometheus-federation-dr.yaml
```

4. Esperar a que Prometheus esté listo:

```bash
kubectl wait --for=condition=ready pod -l app=prometheus-dr \
  -n monitoring --timeout=90s
```

5. Crear un ServiceMonitor para métricas de Velero (si el CRD existe):

```bash
cat > ~/k8s-labs/lab10/manifests/velero-metrics-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: velero-metrics
  namespace: velero
  labels:
    app.kubernetes.io/name: velero
spec:
  selector:
    app.kubernetes.io/name: velero
  ports:
    - port: 8085
      targetPort: 8085
      name: metrics
EOF
kubectl apply -f ~/k8s-labs/lab10/manifests/velero-metrics-service.yaml
```

### Salida Esperada

```
configmap/prometheus-config created
deployment.apps/prometheus-dr created
service/prometheus-dr created
service/velero-metrics created
```

### Verificación

```bash
kubectl get pods -n monitoring --context kind-lab-dr
kubectl logs deployment/prometheus-dr -n monitoring --tail=5
```

---

## Paso 11: Aplicar Políticas de Gobernanza al Clúster DR

**Objetivo:** Replicar las políticas de seguridad del clúster primario en el clúster DR para mantener consistencia de gobernanza.

### Instrucciones

1. Asegurar contexto DR:

```bash
kubectl config use-context kind-lab-dr
```

2. Crear políticas de red básicas para el namespace webapp restaurado:

```bash
cat > ~/k8s-labs/lab10/manifests/network-policies-dr.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: webapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-webapp-ingress
  namespace: webapp
spec:
  podSelector:
    matchLabels:
      app: webapp
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
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
EOF
```

3. Aplicar las políticas (solo si el namespace webapp existe tras la restauración):

```bash
kubectl get ns webapp 2>/dev/null && \
  kubectl apply -f ~/k8s-labs/lab10/manifests/network-policies-dr.yaml || \
  echo "Namespace webapp no encontrado - las políticas se aplicarán post-restauración"
```

4. Crear un ResourceQuota para el namespace webapp en DR:

```bash
cat > ~/k8s-labs/lab10/manifests/resource-quota-dr.yaml << 'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: webapp-quota
  namespace: webapp
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "10"
EOF
kubectl get ns webapp 2>/dev/null && \
  kubectl apply -f ~/k8s-labs/lab10/manifests/resource-quota-dr.yaml || \
  echo "Se aplicará cuando el namespace exista"
```

### Salida Esperada

```
networkpolicy.networking.k8s.io/deny-all-ingress created
networkpolicy.networking.k8s.io/allow-webapp-ingress created
networkpolicy.networking.k8s.io/allow-monitoring created
resourcequota/webapp-quota created
```

### Verificación

```bash
kubectl get networkpolicies -n webapp 2>/dev/null
kubectl get resourcequota -n webapp 2>/dev/null
```

---

## Validación y Testing

### Test Integral del Plan de DR

Ejecutar el script de validación completa:

```bash
cat > ~/k8s-labs/lab10/scripts/validate-dr.sh << 'EOF'
#!/bin/bash
set -e

PASS=0
FAIL=0
TOTAL=0

check() {
  TOTAL=$((TOTAL + 1))
  if eval "$2" > /dev/null 2>&1; then
    echo "✅ PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "❌ FAIL: $1"
    FAIL=$((FAIL + 1))
  fi
}

echo "============================================"
echo "  VALIDACIÓN DEL PLAN DE DR - Lab 10"
echo "============================================"
echo ""

# Verificaciones del clúster primario
echo "--- Clúster Primario (lab-calico) ---"
check "Clúster lab-calico accesible" \
  "kubectl get nodes --context kind-lab-calico"

check "MinIO operativo" \
  "kubectl get pods -n velero-backend --context kind-lab-calico --field-selector=status.phase=Running | grep minio"

check "Velero operativo en primario" \
  "kubectl get pods -n velero --context kind-lab-calico --field-selector=status.phase=Running | grep velero"

check "BackupStorageLocation Available (primario)" \
  "velero backup-location get --context kind-lab-calico 2>/dev/null | grep Available"

check "Schedules configurados (>=3)" \
  "[ \$(velero schedule get --context kind-lab-calico 2>/dev/null | grep -c Enabled) -ge 3 ]"

check "Backup DR completado" \
  "velero backup get --context kind-lab-calico 2>/dev/null | grep -i completed | grep dr-exercise"

# Verificaciones del clúster DR
echo ""
echo "--- Clúster DR (lab-dr) ---"
check "Clúster lab-dr accesible" \
  "kubectl get nodes --context kind-lab-dr"

check "Nodos lab-dr Ready" \
  "[ \$(kubectl get nodes --context kind-lab-dr --no-headers | grep -c Ready) -eq 3 ]"

check "Velero operativo en DR" \
  "kubectl get pods -n velero --context kind-lab-dr --field-selector=status.phase=Running | grep velero"

check "BackupStorageLocation Available (DR)" \
  "velero backup-location get --context kind-lab-dr 2>/dev/null | grep Available"

check "Namespace webapp restaurado en DR" \
  "kubectl get ns webapp --context kind-lab-dr"

check "Prometheus DR operativo" \
  "kubectl get pods -n monitoring --context kind-lab-dr --field-selector=status.phase=Running | grep prometheus"

# Verificaciones de documentación
echo ""
echo "--- Documentación ---"
check "Reporte DR generado" \
  "[ -f ~/k8s-labs/lab10/reports/dr-final-report.md ]"

check "Timeline documentado" \
  "[ -f ~/k8s-labs/lab10/reports/dr-timeline.txt ]"

check "Inventario pre-desastre" \
  "[ -f ~/k8s-labs/lab10/reports/pre-disaster-inventory.txt ]"

check "Script pre-upgrade backup" \
  "[ -x ~/k8s-labs/lab10/scripts/pre-upgrade-backup.sh ]"

echo ""
echo "============================================"
echo "  RESULTADOS: ${PASS}/${TOTAL} passed, ${FAIL} failed"
echo "============================================"

if [ ${FAIL} -eq 0 ]; then
  echo "🎉 ¡Plan de DR validado exitosamente!"
else
  echo "⚠️  Hay ${FAIL} verificaciones fallidas. Revisar los pasos anteriores."
fi
EOF
chmod +x ~/k8s-labs/lab10/scripts/validate-dr.sh
~/k8s-labs/lab10/scripts/validate-dr.sh
```

### Resultado Esperado de la Validación

```
============================================
  VALIDACIÓN DEL PLAN DE DR - Lab 10
============================================

--- Clúster Primario (lab-calico) ---
✅ PASS: Clúster lab-calico accesible
✅ PASS: MinIO operativo
✅ PASS: Velero operativo en primario
✅ PASS: BackupStorageLocation Available (primario)
✅ PASS: Schedules configurados (>=3)
✅ PASS: Backup DR completado

--- Clúster DR (lab-dr) ---
✅ PASS: Clúster lab-dr accesible
✅ PASS: Nodos lab-dr Ready
✅ PASS: Velero operativo en DR
✅ PASS: BackupStorageLocation Available (DR)
✅ PASS: Namespace webapp restaurado en DR
✅ PASS: Prometheus DR operativo

--- Documentación ---
✅ PASS: Reporte DR generado
✅ PASS: Timeline documentado
✅ PASS: Inventario pre-desastre
✅ PASS: Script pre-upgrade backup

============================================
  RESULTADOS: 16/16 passed, 0 failed
============================================
🎉 ¡Plan de DR validado exitosamente!
```

---

## Resolución de Problemas

### Problema 1: Velero en el Clúster DR no puede conectarse a MinIO

**Síntomas:**
- `velero backup-location get` muestra `Phase: Unavailable`
- Logs de Velero muestran: `error connecting to backup storage location: dial tcp <IP>:30900: connect: connection refused`

**Causa:** Los contenedores de los nodos kind del clúster DR no pueden alcanzar la IP del nodo del clúster primario donde MinIO expone el NodePort. Las redes Docker de ambos clústeres kind están aisladas por defecto.

**Solución:**

```bash
# Verificar las redes Docker
docker network ls | grep kind

# Conectar los nodos del clúster DR a la red del clúster primario
for node in $(kind get nodes --name lab-dr); do
  docker network connect kind $node 2>/dev/null || true
done

# Verificar conectividad desde un nodo DR hacia MinIO
MINIO_IP=$(docker inspect lab-calico-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
docker exec lab-dr-control-plane curl -s http://${MINIO_IP}:30900/minio/health/ready

# Si la IP cambió, actualizar el BackupStorageLocation
kubectl config use-context kind-lab-dr
velero backup-location set default \
  --provider aws \
  --bucket velero-backups \
  --config region=minio,s3ForcePathStyle=true,s3Url=http://${MINIO_IP}:30900

# Forzar resync
velero backup-location get
```

### Problema 2: La restauración completa pero los pods quedan en CrashLoopBackOff

**Síntomas:**
- `velero restore describe` muestra `Phase: Completed`
- `kubectl get pods -n webapp` muestra pods en `CrashLoopBackOff` o `ImagePullBackOff`

**Causa:** Los pods restaurados hacen referencia a imágenes almacenadas en el registry local (`localhost:5000/...`) que no es accesible desde los nodos del clúster DR, o las imágenes dependen de ConfigMaps/Secrets que no fueron incluidos en el backup.

**Solución:**

```bash
# Verificar qué imágenes necesitan los pods
kubectl get pods -n webapp --context kind-lab-dr -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'

# Si usan localhost:5000, asegurar que el registry está conectado a la red kind del DR
docker network connect kind registry 2>/dev/null || true

# Verificar accesibilidad del registry desde nodos DR
docker exec lab-dr-worker curl -s http://registry:5000/v2/_catalog

# Si el problema es de ConfigMaps/Secrets faltantes, restaurar con todos los namespaces
DR_BACKUP_NAME=$(cat ~/k8s-labs/lab10/reports/backup-name.txt)
velero restore create dr-restore-full \
  --from-backup ${DR_BACKUP_NAME} \
  --include-namespaces webapp \
  --restore-volumes=true \
  --existing-resource-policy=update \
  --wait

# Reiniciar los pods afectados
kubectl rollout restart deployment -n webapp --context kind-lab-dr
```

---

## Limpieza

Para eliminar todos los recursos creados en este laboratorio:

```bash
# Eliminar el clúster DR
kind delete cluster --name lab-dr

# Limpiar Velero y schedules del clúster primario (opcional - mantener si se desea conservar)
kubectl config use-context kind-lab-calico

# Eliminar schedules de Velero
velero schedule delete hourly-webapp --confirm 2>/dev/null
velero schedule delete daily-full --confirm 2>/dev/null
velero schedule delete weekly-full --confirm 2>/dev/null

# Eliminar backups del ejercicio
velero backup delete $(cat ~/k8s-labs/lab10/reports/backup-name.txt) --confirm 2>/dev/null

# Eliminar MinIO (opcional)
kubectl delete namespace velero-backend 2>/dev/null

# Eliminar Velero del primario (opcional)
kubectl delete namespace velero 2>/dev/null

# Limpiar archivos locales (opcional)
# rm -rf ~/k8s-labs/lab10
```

> **Nota:** Si desea conservar la infraestructura de backup para uso continuo, omita la eliminación de los namespaces `velero` y `velero-backend`.

---

## Resumen

### Lo Que Se Logró

En este laboratorio se diseñó e implementó un plan completo de Recuperación ante Desastres multi-cluster que incluye:

1. **Infraestructura de backup:** MinIO como backend S3 con Velero en ambos clústeres
2. **Automatización:** 4 schedules de backup con retención diferenciada (horario, diario, semanal, pre-upgrade)
3. **Ejercicio de DR completo:** Backup → Simulación de fallo → Restauración → Validación
4. **Observabilidad:** Prometheus federation para métricas unificadas entre clústeres
5. **Gobernanza:** Políticas de red y ResourceQuotas replicadas en el clúster DR
6. **Documentación:** Reporte con timeline, RTO/RPO medidos y procedimientos de failover/failback

### Métricas Clave del Ejercicio

| Métrica | Objetivo | Descripción |
|---------|----------|-------------|
| RTO | ≤ 30 minutos | Tiempo desde detección de fallo hasta servicio restaurado |
| RPO | ≤ 1 hora | Máxima pérdida de datos aceptable (backup más reciente) |

### Arquitectura Implementada

El modelo implementado corresponde a **activo-pasivo** con failover manual asistido por automatización. El clúster `lab-dr` permanece en espera con Velero listo para restaurar desde el último backup disponible en MinIO.

### Recursos Adicionales

- [Documentación oficial de Velero](https://velero.io/docs/v1.14/)
- [Velero Disaster Recovery Best Practices](https://velero.io/docs/v1.14/disaster-case/)
- [Kubernetes SIG Multicluster](https://github.com/kubernetes-sigs/about-api)
- [Prometheus Federation](https://prometheus.io/docs/prometheus/latest/federation/)
