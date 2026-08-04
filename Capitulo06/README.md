# Desarrollar un Operator Básico y Desplegar CRDs

## Metadata

| Campo | Valor |
|-------|-------|
| **Duración** | 43 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |

## Descripción General

En este laboratorio se diseñará e implementará un Operator completo en Go usando kubebuilder. Se creará el CRD `WebAppDeployment` con dos versiones (v1alpha1 y v1beta1), se implementará la lógica de reconciliación que gestiona Deployments, Services y ConfigMaps, se configurará un conversion webhook entre versiones, y se desplegará el Operator en el clúster `lab-calico` con RBAC mínimo. Al finalizar, tres instancias del recurso personalizado validarán el ciclo completo de vida.

## Objetivos de Aprendizaje

- [ ] Diseñar un CRD `WebAppDeployment` con esquema OpenAPI v3, subrecurso status y múltiples versiones
- [ ] Implementar un controlador con lógica de reconciliación usando controller-runtime (watches, predicates, rate limiting)
- [ ] Configurar un conversion webhook para migración entre v1alpha1 y v1beta1
- [ ] Construir y desplegar el Operator en el clúster con RBAC mínimo necesario
- [ ] Validar el ciclo completo: creación, actualización y eliminación de recursos personalizados

## Prerrequisitos

### Conocimiento Requerido

- Programación en Go (structs, interfaces, punteros)
- Patrones de reconciliación de Kubernetes (spec/status)
- Conceptos de CRDs y esquemas OpenAPI v3 (lección 6.1)
- Familiaridad con controller-runtime y kubebuilder

### Acceso y Software

| Componente | Versión | Verificación |
|-----------|---------|--------------|
| Clúster `lab-calico` | kind 0.23.0 / K8s 1.30.2 | `kubectl cluster-info --context kind-lab-calico` |
| Registry local | localhost:5000 | `curl -s http://localhost:5000/v2/_catalog` |
| cert-manager | 1.15.1 | `kubectl get pods -n cert-manager` |
| Go | 1.22.4 | `go version` |
| kubebuilder | 3.15.1 | `kubebuilder version` |
| Operator SDK | 1.35.0 | `operator-sdk version` |
| controller-gen | 0.15.0 | `controller-gen --version` |
| Docker | 26.1.4 | `docker version --format '{{.Server.Version}}'` |

## Entorno del Laboratorio

### Preparación del Directorio

```bash
mkdir -p ~/k8s-labs/lab06
cd ~/k8s-labs/lab06
kubectl config use-context kind-lab-calico
```

### Verificar Prerrequisitos

```bash
# Verificar clúster operativo
kubectl get nodes -o wide

# Verificar cert-manager (necesario para webhooks)
kubectl get pods -n cert-manager --no-headers | grep -c Running

# Verificar registry local
docker ps --filter name=registry --format '{{.Names}} {{.Status}}'

# Verificar herramientas Go
go version && kubebuilder version && controller-gen --version
```

**Salida esperada:**
```
NAME                       STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
lab-calico-control-plane   Ready    control-plane   ...   v1.30.2   ...
lab-calico-worker          Ready    <none>          ...   v1.30.2   ...
lab-calico-worker2         Ready    <none>          ...   v1.30.2   ...
3
registry Up ...
go version go1.22.4 linux/amd64
...
```

---

## Paso 1: Scaffolding del Proyecto con Kubebuilder

**Objetivo:** Inicializar la estructura del proyecto del Operator usando kubebuilder con el dominio y grupo correctos.

### Instrucciones

1. Crear el directorio del proyecto e inicializar:

```bash
mkdir -p ~/k8s-labs/lab06/webapp-operator
cd ~/k8s-labs/lab06/webapp-operator

kubebuilder init \
  --domain lab.local \
  --repo github.com/lab/webapp-operator \
  --project-name webapp-operator
```

2. Crear la API para la versión v1alpha1:

```bash
kubebuilder create api \
  --group apps \
  --version v1alpha1 \
  --kind WebAppDeployment \
  --resource --controller
```

3. Crear la API para la versión v1beta1 (solo recurso, sin controlador duplicado):

```bash
kubebuilder create api \
  --group apps \
  --version v1beta1 \
  --kind WebAppDeployment \
  --resource --controller=false
```

4. Verificar la estructura generada:

```bash
find . -type f -name "*.go" | head -20
ls -la api/v1alpha1/ api/v1beta1/
```

**Salida esperada:**
```
./api/v1alpha1/webappdeployment_types.go
./api/v1alpha1/groupversion_info.go
./api/v1alpha1/zz_generated.deepcopy.go
./api/v1beta1/webappdeployment_types.go
./api/v1beta1/groupversion_info.go
./internal/controller/webappdeployment_controller.go
./cmd/main.go
...
```

**Verificación:**
```bash
grep -r "GroupVersion" api/v1alpha1/groupversion_info.go
grep -r "GroupVersion" api/v1beta1/groupversion_info.go
```

---

## Paso 2: Definir los Tipos del CRD (v1alpha1 y v1beta1)

**Objetivo:** Implementar los structs Go con marcadores kubebuilder que generarán el esquema OpenAPI v3 con validación, subrecursos status y condiciones.

### Instrucciones

1. Editar el tipo v1alpha1:

```bash
cat > api/v1alpha1/webappdeployment_types.go << 'EOF'
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebAppDeploymentSpec define el estado deseado de WebAppDeployment
type WebAppDeploymentSpec struct {
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Image string `json:"image"`

	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=1
	FrontendReplicas int32 `json:"frontendReplicas"`

	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=1
	BackendReplicas int32 `json:"backendReplicas"`

	// +kubebuilder:validation:Required
	Resources ResourceRequirements `json:"resources"`

	// +kubebuilder:validation:Enum=RollingUpdate;Recreate
	// +kubebuilder:default=RollingUpdate
	UpdateStrategy string `json:"updateStrategy,omitempty"`
}

// ResourceRequirements define los límites de CPU y memoria
type ResourceRequirements struct {
	// +kubebuilder:validation:Pattern=`^[0-9]+m$`
	CPULimit string `json:"cpuLimit"`

	// +kubebuilder:validation:Pattern=`^[0-9]+(Mi|Gi)$`
	MemoryLimit string `json:"memoryLimit"`

	// +kubebuilder:validation:Pattern=`^[0-9]+m$`
	CPURequest string `json:"cpuRequest"`

	// +kubebuilder:validation:Pattern=`^[0-9]+(Mi|Gi)$`
	MemoryRequest string `json:"memoryRequest"`
}

// WebAppDeploymentStatus define el estado observado de WebAppDeployment
type WebAppDeploymentStatus struct {
	ReadyReplicas    int32              `json:"readyReplicas,omitempty"`
	AvailableReplicas int32            `json:"availableReplicas,omitempty"`
	Conditions       []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wad
// +kubebuilder:printcolumn:name="Frontend",type=integer,JSONPath=`.spec.frontendReplicas`
// +kubebuilder:printcolumn:name="Backend",type=integer,JSONPath=`.spec.backendReplicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// WebAppDeployment es el Schema para la API webappdeployments
type WebAppDeployment struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppDeploymentSpec   `json:"spec,omitempty"`
	Status WebAppDeploymentStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebAppDeploymentList contiene una lista de WebAppDeployment
type WebAppDeploymentList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebAppDeployment `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebAppDeployment{}, &WebAppDeploymentList{})
}
EOF
```

2. Editar el tipo v1beta1 (versión evolucionada con campo adicional `configData`):

```bash
cat > api/v1beta1/webappdeployment_types.go << 'EOF'
package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WebAppDeploymentSpec define el estado deseado de WebAppDeployment v1beta1
type WebAppDeploymentSpec struct {
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	Image string `json:"image"`

	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=1
	FrontendReplicas int32 `json:"frontendReplicas"`

	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	// +kubebuilder:default=1
	BackendReplicas int32 `json:"backendReplicas"`

	// +kubebuilder:validation:Required
	Resources ResourceRequirements `json:"resources"`

	// +kubebuilder:validation:Enum=RollingUpdate;Recreate
	// +kubebuilder:default=RollingUpdate
	UpdateStrategy string `json:"updateStrategy,omitempty"`

	// ConfigData contiene configuración adicional para la aplicación
	// +optional
	ConfigData map[string]string `json:"configData,omitempty"`
}

// ResourceRequirements define los límites de CPU y memoria
type ResourceRequirements struct {
	// +kubebuilder:validation:Pattern=`^[0-9]+m$`
	CPULimit string `json:"cpuLimit"`

	// +kubebuilder:validation:Pattern=`^[0-9]+(Mi|Gi)$`
	MemoryLimit string `json:"memoryLimit"`

	// +kubebuilder:validation:Pattern=`^[0-9]+m$`
	CPURequest string `json:"cpuRequest"`

	// +kubebuilder:validation:Pattern=`^[0-9]+(Mi|Gi)$`
	MemoryRequest string `json:"memoryRequest"`
}

// WebAppDeploymentStatus define el estado observado
type WebAppDeploymentStatus struct {
	ReadyReplicas     int32              `json:"readyReplicas,omitempty"`
	AvailableReplicas int32              `json:"availableReplicas,omitempty"`
	Conditions        []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wad
// +kubebuilder:storageversion
// +kubebuilder:printcolumn:name="Frontend",type=integer,JSONPath=`.spec.frontendReplicas`
// +kubebuilder:printcolumn:name="Backend",type=integer,JSONPath=`.spec.backendReplicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// WebAppDeployment es el Schema para la API webappdeployments v1beta1
type WebAppDeployment struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppDeploymentSpec   `json:"spec,omitempty"`
	Status WebAppDeploymentStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebAppDeploymentList contiene una lista de WebAppDeployment
type WebAppDeploymentList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebAppDeployment `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebAppDeployment{}, &WebAppDeploymentList{})
}
EOF
```

3. Generar deepcopy y manifests:

```bash
make generate
make manifests
```

**Verificación:**
```bash
# Verificar que el CRD generado tiene ambas versiones
cat config/crd/bases/apps.lab.local_webappdeployments.yaml | grep "version:" | head -5
# Verificar que v1beta1 es storage version
grep -A2 "storage:" config/crd/bases/apps.lab.local_webappdeployments.yaml
```

---

## Paso 3: Implementar el Controlador de Reconciliación

**Objetivo:** Desarrollar la lógica de reconciliación que crea y gestiona Deployments, Services y ConfigMaps basándose en el estado deseado del CRD.

### Instrucciones

1. Implementar el controlador completo:

```bash
cat > internal/controller/webappdeployment_controller.go << 'EOF'
package controller

import (
	"context"
	"fmt"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/workqueue"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	appsv1alpha1 "github.com/lab/webapp-operator/api/v1alpha1"
)

const (
	finalizerName = "apps.lab.local/finalizer"
)

// WebAppDeploymentReconciler reconcilia objetos WebAppDeployment
type WebAppDeploymentReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=apps.lab.local,resources=webappdeployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.lab.local,resources=webappdeployments/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps.lab.local,resources=webappdeployments/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch;delete

func (r *WebAppDeploymentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Obtener el recurso WebAppDeployment
	webapp := &appsv1alpha1.WebAppDeployment{}
	if err := r.Get(ctx, req.NamespacedName, webapp); err != nil {
		if errors.IsNotFound(err) {
			logger.Info("WebAppDeployment eliminado, nada que reconciliar")
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Manejar finalizer
	if webapp.ObjectMeta.DeletionTimestamp.IsZero() {
		if !controllerutil.ContainsFinalizer(webapp, finalizerName) {
			controllerutil.AddFinalizer(webapp, finalizerName)
			if err := r.Update(ctx, webapp); err != nil {
				return ctrl.Result{}, err
			}
		}
	} else {
		if controllerutil.ContainsFinalizer(webapp, finalizerName) {
			logger.Info("Ejecutando lógica de limpieza del finalizer")
			controllerutil.RemoveFinalizer(webapp, finalizerName)
			if err := r.Update(ctx, webapp); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Reconciliar ConfigMap
	if err := r.reconcileConfigMap(ctx, webapp); err != nil {
		return r.updateStatusDegraded(ctx, webapp, err)
	}

	// Reconciliar Deployment Frontend
	if err := r.reconcileDeployment(ctx, webapp, "frontend", webapp.Spec.FrontendReplicas); err != nil {
		return r.updateStatusDegraded(ctx, webapp, err)
	}

	// Reconciliar Deployment Backend
	if err := r.reconcileDeployment(ctx, webapp, "backend", webapp.Spec.BackendReplicas); err != nil {
		return r.updateStatusDegraded(ctx, webapp, err)
	}

	// Reconciliar Service
	if err := r.reconcileService(ctx, webapp); err != nil {
		return r.updateStatusDegraded(ctx, webapp, err)
	}

	// Actualizar status
	return r.updateStatusAvailable(ctx, webapp)
}

func (r *WebAppDeploymentReconciler) reconcileConfigMap(ctx context.Context, webapp *appsv1alpha1.WebAppDeployment) error {
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-config", webapp.Name),
			Namespace: webapp.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{
			"APP_NAME":       webapp.Name,
			"FRONTEND_REPLICAS": fmt.Sprintf("%d", webapp.Spec.FrontendReplicas),
			"BACKEND_REPLICAS":  fmt.Sprintf("%d", webapp.Spec.BackendReplicas),
		}
		return controllerutil.SetControllerReference(webapp, cm, r.Scheme)
	})
	return err
}

func (r *WebAppDeploymentReconciler) reconcileDeployment(ctx context.Context, webapp *appsv1alpha1.WebAppDeployment, component string, replicas int32) error {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-%s", webapp.Name, component),
			Namespace: webapp.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		labels := map[string]string{
			"app":       webapp.Name,
			"component": component,
			"managed-by": "webapp-operator",
		}
		deploy.Spec = appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: labels,
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: labels,
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  component,
							Image: webapp.Spec.Image,
							Resources: corev1.ResourceRequirements{
								Limits: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse(webapp.Spec.Resources.CPULimit),
									corev1.ResourceMemory: resource.MustParse(webapp.Spec.Resources.MemoryLimit),
								},
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse(webapp.Spec.Resources.CPURequest),
									corev1.ResourceMemory: resource.MustParse(webapp.Spec.Resources.MemoryRequest),
								},
							},
							EnvFrom: []corev1.EnvFromSource{
								{
									ConfigMapRef: &corev1.ConfigMapEnvSource{
										LocalObjectReference: corev1.LocalObjectReference{
											Name: fmt.Sprintf("%s-config", webapp.Name),
										},
									},
								},
							},
						},
					},
				},
			},
		}
		return controllerutil.SetControllerReference(webapp, deploy, r.Scheme)
	})
	return err
}

func (r *WebAppDeploymentReconciler) reconcileService(ctx context.Context, webapp *appsv1alpha1.WebAppDeployment) error {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-svc", webapp.Name),
			Namespace: webapp.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec = corev1.ServiceSpec{
			Selector: map[string]string{
				"app":       webapp.Name,
				"component": "frontend",
			},
			Ports: []corev1.ServicePort{
				{
					Name:     "http",
					Port:     80,
					Protocol: corev1.ProtocolTCP,
				},
			},
			Type: corev1.ServiceTypeClusterIP,
		}
		return controllerutil.SetControllerReference(webapp, svc, r.Scheme)
	})
	return err
}

func (r *WebAppDeploymentReconciler) updateStatusAvailable(ctx context.Context, webapp *appsv1alpha1.WebAppDeployment) (ctrl.Result, error) {
	// Obtener réplicas listas de ambos deployments
	frontendDeploy := &appsv1.Deployment{}
	backendDeploy := &appsv1.Deployment{}

	var totalReady int32

	if err := r.Get(ctx, types.NamespacedName{
		Name: fmt.Sprintf("%s-frontend", webapp.Name), Namespace: webapp.Namespace,
	}, frontendDeploy); err == nil {
		totalReady += frontendDeploy.Status.ReadyReplicas
	}

	if err := r.Get(ctx, types.NamespacedName{
		Name: fmt.Sprintf("%s-backend", webapp.Name), Namespace: webapp.Namespace,
	}, backendDeploy); err == nil {
		totalReady += backendDeploy.Status.ReadyReplicas
	}

	webapp.Status.ReadyReplicas = totalReady
	webapp.Status.AvailableReplicas = totalReady

	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:               "Available",
		Status:             metav1.ConditionTrue,
		Reason:             "ReconcileSuccess",
		Message:            "Todos los componentes reconciliados correctamente",
		LastTransitionTime: metav1.Now(),
	})

	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:               "Progressing",
		Status:             metav1.ConditionFalse,
		Reason:             "ReconcileComplete",
		Message:            "Reconciliación completada",
		LastTransitionTime: metav1.Now(),
	})

	if err := r.Status().Update(ctx, webapp); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

func (r *WebAppDeploymentReconciler) updateStatusDegraded(ctx context.Context, webapp *appsv1alpha1.WebAppDeployment, reconcileErr error) (ctrl.Result, error) {
	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:               "Degraded",
		Status:             metav1.ConditionTrue,
		Reason:             "ReconcileError",
		Message:            reconcileErr.Error(),
		LastTransitionTime: metav1.Now(),
	})

	if err := r.Status().Update(ctx, webapp); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: 10 * time.Second}, reconcileErr
}

// SetupWithManager configura el controlador con watches y predicates
func (r *WebAppDeploymentReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsv1alpha1.WebAppDeployment{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		WithOptions(controller.Options{
			MaxConcurrentReconciles: 2,
			RateLimiter: workqueue.NewItemExponentialFailureRateLimiter(
				time.Second,
				30*time.Second,
			),
		}).
		WithEventFilter(predicate.GenerationChangedPredicate{}).
		Complete(r)
}
EOF
```

2. Regenerar manifests con los nuevos marcadores RBAC:

```bash
make manifests
```

**Verificación:**
```bash
# Verificar que el RBAC se generó correctamente
cat config/rbac/role.yaml | grep -A5 "rules:"
```

---

## Paso 4: Implementar el Conversion Webhook

**Objetivo:** Configurar un webhook de conversión que permita migrar recursos entre v1alpha1 y v1beta1 de forma transparente.

### Instrucciones

1. Crear el scaffold del webhook:

```bash
kubebuilder create webhook \
  --group apps \
  --version v1alpha1 \
  --kind WebAppDeployment \
  --conversion
```

2. Implementar la interfaz Hub en v1beta1 (versión de almacenamiento):

```bash
cat > api/v1beta1/webappdeployment_conversion.go << 'EOF'
package v1beta1

// Hub marca v1beta1 como la versión hub para conversión
func (*WebAppDeployment) Hub() {}
EOF
```

3. Implementar la interfaz Convertible en v1alpha1 (spoke):

```bash
cat > api/v1alpha1/webappdeployment_conversion.go << 'EOF'
package v1alpha1

import (
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	v1beta1 "github.com/lab/webapp-operator/api/v1beta1"
)

// ConvertTo convierte v1alpha1 a v1beta1 (hub)
func (src *WebAppDeployment) ConvertTo(dstRaw conversion.Hub) error {
	dst := dstRaw.(*v1beta1.WebAppDeployment)

	// ObjectMeta
	dst.ObjectMeta = src.ObjectMeta

	// Spec
	dst.Spec.Image = src.Spec.Image
	dst.Spec.FrontendReplicas = src.Spec.FrontendReplicas
	dst.Spec.BackendReplicas = src.Spec.BackendReplicas
	dst.Spec.UpdateStrategy = src.Spec.UpdateStrategy
	dst.Spec.Resources = v1beta1.ResourceRequirements{
		CPULimit:      src.Spec.Resources.CPULimit,
		MemoryLimit:   src.Spec.Resources.MemoryLimit,
		CPURequest:    src.Spec.Resources.CPURequest,
		MemoryRequest: src.Spec.Resources.MemoryRequest,
	}
	// ConfigData no existe en v1alpha1, se inicializa vacío
	dst.Spec.ConfigData = map[string]string{}

	// Status
	dst.Status.ReadyReplicas = src.Status.ReadyReplicas
	dst.Status.AvailableReplicas = src.Status.AvailableReplicas
	dst.Status.Conditions = src.Status.Conditions

	return nil
}

// ConvertFrom convierte de v1beta1 (hub) a v1alpha1
func (dst *WebAppDeployment) ConvertFrom(srcRaw conversion.Hub) error {
	src := srcRaw.(*v1beta1.WebAppDeployment)

	// ObjectMeta
	dst.ObjectMeta = src.ObjectMeta

	// Spec
	dst.Spec.Image = src.Spec.Image
	dst.Spec.FrontendReplicas = src.Spec.FrontendReplicas
	dst.Spec.BackendReplicas = src.Spec.BackendReplicas
	dst.Spec.UpdateStrategy = src.Spec.UpdateStrategy
	dst.Spec.Resources = ResourceRequirements{
		CPULimit:      src.Spec.Resources.CPULimit,
		MemoryLimit:   src.Spec.Resources.MemoryLimit,
		CPURequest:    src.Spec.Resources.CPURequest,
		MemoryRequest: src.Spec.Resources.MemoryRequest,
	}
	// ConfigData se pierde en la conversión a v1alpha1 (campo no existe)

	// Status
	dst.Status.ReadyReplicas = src.Status.ReadyReplicas
	dst.Status.AvailableReplicas = src.Status.AvailableReplicas
	dst.Status.Conditions = src.Status.Conditions

	return nil
}
EOF
```

4. Habilitar la configuración de webhook en `config/crd/kustomization.yaml`:

```bash
cd ~/k8s-labs/lab06/webapp-operator

# Habilitar patches de webhook en CRD kustomization
sed -i 's|#- patches/webhook_in_webappdeployments.yaml|- patches/webhook_in_webappdeployments.yaml|' config/crd/kustomization.yaml
sed -i 's|#- patches/cainjection_in_webappdeployments.yaml|- patches/cainjection_in_webappdeployments.yaml|' config/crd/kustomization.yaml
```

5. Habilitar el webhook en `config/default/kustomization.yaml`:

```bash
sed -i 's|#- ../webhook|- ../webhook|' config/default/kustomization.yaml
sed -i 's|#- ../certmanager|- ../certmanager|' config/default/kustomization.yaml
sed -i 's|#- manager_webhook_patch.yaml|- manager_webhook_patch.yaml|' config/default/kustomization.yaml
sed -i 's|#- webhookcainjection_patch.yaml|- webhookcainjection_patch.yaml|' config/default/kustomization.yaml
```

6. Descomentar las variables de cert-manager en `config/default/kustomization.yaml`:

```bash
# Descomentar las replacements de cert-manager
sed -i 's|#- source:|- source:|g' config/default/kustomization.yaml
sed -i 's|#    kind: Certificate|    kind: Certificate|g' config/default/kustomization.yaml
sed -i 's|#    group: cert-manager.io|    group: cert-manager.io|g' config/default/kustomization.yaml
sed -i 's|#    version: v1|    version: v1|g' config/default/kustomization.yaml
sed -i 's|#    name: serving-cert|    name: serving-cert|g' config/default/kustomization.yaml
sed -i 's|#    namespace: system|    namespace: system|g' config/default/kustomization.yaml
sed -i 's|#    fieldPath:|    fieldPath:|g' config/default/kustomization.yaml
sed -i 's|#  targets:|  targets:|g' config/default/kustomization.yaml
```

7. Regenerar manifests:

```bash
make generate
make manifests
```

**Verificación:**
```bash
# Verificar que el CRD tiene configuración de conversion webhook
grep -A5 "conversion:" config/crd/bases/apps.lab.local_webappdeployments.yaml || echo "Se configurará via kustomize patches"
ls config/webhook/
```

---

## Paso 5: Compilar y Publicar la Imagen del Operator

**Objetivo:** Construir la imagen Docker del Operator y publicarla en el registry local para su despliegue en el clúster.

### Instrucciones

1. Actualizar las dependencias del módulo Go:

```bash
cd ~/k8s-labs/lab06/webapp-operator
go mod tidy
```

2. Verificar que el código compila correctamente:

```bash
go build ./...
```

3. Configurar el Makefile para usar el registry local:

```bash
# Establecer la imagen del Operator
export IMG=localhost:5000/webapp-operator:v0.1.0
```

4. Construir la imagen Docker:

```bash
make docker-build IMG=${IMG}
```

5. Publicar la imagen en el registry local:

```bash
make docker-push IMG=${IMG}
```

6. Cargar la imagen en los nodos del clúster kind:

```bash
kind load docker-image ${IMG} --name lab-calico
```

**Salida esperada:**
```
Image: "localhost:5000/webapp-operator:v0.1.0" with ID "sha256:..." not yet present on node "lab-calico-worker", loading...
Image: "localhost:5000/webapp-operator:v0.1.0" with ID "sha256:..." not yet present on node "lab-calico-worker2", loading...
Image: "localhost:5000/webapp-operator:v0.1.0" with ID "sha256:..." not yet present on node "lab-calico-control-plane", loading...
```

**Verificación:**
```bash
# Verificar que la imagen está en el registry
curl -s http://localhost:5000/v2/webapp-operator/tags/list
# Salida esperada: {"name":"webapp-operator","tags":["v0.1.0"]}

# Verificar la imagen en Docker local
docker images | grep webapp-operator
```

---

## Paso 6: Desplegar el Operator en el Clúster

**Objetivo:** Instalar el CRD, RBAC y el Deployment del Operator en el namespace `webapp-operator-system` con los permisos mínimos necesarios.

### Instrucciones

1. Crear el namespace del Operator:

```bash
kubectl create namespace webapp-operator-system --dry-run=client -o yaml | kubectl apply -f -
```

2. Desplegar el Operator usando kustomize (incluye CRD, RBAC, Deployment y Webhook):

```bash
cd ~/k8s-labs/lab06/webapp-operator
make deploy IMG=localhost:5000/webapp-operator:v0.1.0
```

3. Verificar que el CRD fue registrado:

```bash
kubectl get crds webappdeployments.apps.lab.local
```

**Salida esperada:**
```
NAME                                CREATED AT
webappdeployments.apps.lab.local    2024-...
```

4. Verificar que el Operator está corriendo:

```bash
kubectl get pods -n webapp-operator-system -w
```

**Salida esperada (esperar hasta Running):**
```
NAME                                                  READY   STATUS    RESTARTS   AGE
webapp-operator-controller-manager-xxxxxxxxxx-xxxxx   2/2     Running   0          30s
```

5. Verificar los roles RBAC creados:

```bash
kubectl get clusterroles | grep webapp-operator
kubectl describe clusterrole webapp-operator-manager-role
```

6. Verificar el webhook de conversión (si cert-manager generó el certificado):

```bash
kubectl get certificate -n webapp-operator-system
kubectl get validatingwebhookconfigurations 2>/dev/null | grep webapp || true
```

**Verificación:**
```bash
# Verificar logs del Operator
kubectl logs -n webapp-operator-system deployment/webapp-operator-controller-manager -c manager --tail=20

# Verificar que el CRD acepta ambas versiones
kubectl api-resources | grep webappdeployment
```

---

## Paso 7: Crear Instancias de WebAppDeployment y Validar el Ciclo de Vida

**Objetivo:** Crear 3 instancias del CRD, verificar que el Operator reconcilia correctamente creando los recursos hijos, y validar actualización y eliminación.

### Instrucciones

1. Crear el namespace de la aplicación:

```bash
kubectl create namespace webapp --dry-run=client -o yaml | kubectl apply -f -
```

2. Crear la primera instancia (producción):

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps.lab.local/v1alpha1
kind: WebAppDeployment
metadata:
  name: webapp-production
  namespace: webapp
spec:
  image: nginx:1.25-alpine
  frontendReplicas: 3
  backendReplicas: 2
  updateStrategy: RollingUpdate
  resources:
    cpuLimit: "500m"
    memoryLimit: "256Mi"
    cpuRequest: "100m"
    memoryRequest: "128Mi"
EOF
```

3. Crear la segunda instancia (staging):

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps.lab.local/v1alpha1
kind: WebAppDeployment
metadata:
  name: webapp-staging
  namespace: webapp
spec:
  image: nginx:1.25-alpine
  frontendReplicas: 2
  backendReplicas: 1
  updateStrategy: RollingUpdate
  resources:
    cpuLimit: "250m"
    memoryLimit: "128Mi"
    cpuRequest: "50m"
    memoryRequest: "64Mi"
EOF
```

4. Crear la tercera instancia usando v1beta1 (desarrollo con configData):

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps.lab.local/v1beta1
kind: WebAppDeployment
metadata:
  name: webapp-development
  namespace: webapp
spec:
  image: nginx:1.25-alpine
  frontendReplicas: 1
  backendReplicas: 1
  updateStrategy: Recreate
  resources:
    cpuLimit: "200m"
    memoryLimit: "128Mi"
    cpuRequest: "50m"
    memoryRequest: "64Mi"
  configData:
    LOG_LEVEL: "debug"
    ENVIRONMENT: "development"
EOF
```

5. Verificar que el Operator creó los recursos hijos:

```bash
# Listar los WebAppDeployments
kubectl get wad -n webapp

# Verificar Deployments creados
kubectl get deployments -n webapp -l managed-by=webapp-operator

# Verificar Services creados
kubectl get svc -n webapp

# Verificar ConfigMaps creados
kubectl get configmaps -n webapp
```

**Salida esperada:**
```
NAME                 FRONTEND   BACKEND   READY   AGE
webapp-production    3          2         5       60s
webapp-staging       2          1         3       45s
webapp-development   1          1         2       30s

NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
webapp-production-frontend       3/3     3            3           60s
webapp-production-backend        2/2     2            2           60s
webapp-staging-frontend          2/2     2            2           45s
webapp-staging-backend           1/1     1            1           45s
webapp-development-frontend      1/1     1            1           30s
webapp-development-backend       1/1     1            1           30s
```

6. Verificar el status con condiciones:

```bash
kubectl get wad webapp-production -n webapp -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

**Salida esperada:**
```json
[
    {
        "type": "Available",
        "status": "True",
        "reason": "ReconcileSuccess",
        "message": "Todos los componentes reconciliados correctamente",
        ...
    },
    {
        "type": "Progressing",
        "status": "False",
        "reason": "ReconcileComplete",
        ...
    }
]
```

7. Validar actualización — escalar frontend de producción:

```bash
kubectl patch wad webapp-production -n webapp --type=merge \
  -p '{"spec":{"frontendReplicas":5}}'

# Esperar reconciliación
sleep 10

# Verificar que se escaló
kubectl get deployment webapp-production-frontend -n webapp
```

**Salida esperada:**
```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
webapp-production-frontend     5/5     5            5           2m
```

8. Validar eliminación — eliminar la instancia de staging:

```bash
kubectl delete wad webapp-staging -n webapp

# Verificar que los recursos hijos fueron eliminados (Owner References)
sleep 5
kubectl get deployments -n webapp | grep staging
kubectl get svc -n webapp | grep staging
kubectl get configmaps -n webapp | grep staging
```

**Salida esperada:**
```
(sin resultados — los recursos fueron eliminados por garbage collection)
```

9. Validar conversión entre versiones — leer producción como v1beta1:

```bash
kubectl get webappdeployments.v1beta1.apps.lab.local webapp-production -n webapp -o yaml | grep -A3 "configData"
```

**Verificación final:**
```bash
# Resumen completo del estado
echo "=== WebAppDeployments ==="
kubectl get wad -n webapp
echo ""
echo "=== Deployments ==="
kubectl get deployments -n webapp
echo ""
echo "=== Services ==="
kubectl get svc -n webapp
echo ""
echo "=== Pods ==="
kubectl get pods -n webapp --show-labels | grep managed-by
echo ""
echo "=== Operator Logs (últimas 10 líneas) ==="
kubectl logs -n webapp-operator-system deployment/webapp-operator-controller-manager -c manager --tail=10
```

---

## Validación y Testing

Ejecutar las siguientes verificaciones para confirmar que el laboratorio se completó correctamente:

```bash
#!/bin/bash
echo "========================================="
echo " VALIDACIÓN COMPLETA - Lab 06"
echo "========================================="

PASS=0
FAIL=0

# Test 1: CRD registrado
if kubectl get crd webappdeployments.apps.lab.local &>/dev/null; then
  echo "✅ CRD webappdeployments.apps.lab.local registrado"
  ((PASS++))
else
  echo "❌ CRD no encontrado"
  ((FAIL++))
fi

# Test 2: Operator corriendo
OPERATOR_READY=$(kubectl get pods -n webapp-operator-system -l control-plane=controller-manager --no-headers 2>/dev/null | grep Running | wc -l)
if [ "$OPERATOR_READY" -ge 1 ]; then
  echo "✅ Operator corriendo en webapp-operator-system"
  ((PASS++))
else
  echo "❌ Operator no está corriendo"
  ((FAIL++))
fi

# Test 3: Instancias de WebAppDeployment
WAD_COUNT=$(kubectl get wad -n webapp --no-headers 2>/dev/null | wc -l)
if [ "$WAD_COUNT" -ge 2 ]; then
  echo "✅ ${WAD_COUNT} instancias de WebAppDeployment activas"
  ((PASS++))
else
  echo "❌ Se esperaban al menos 2 instancias, encontradas: ${WAD_COUNT}"
  ((FAIL++))
fi

# Test 4: Deployments creados por el Operator
DEPLOY_COUNT=$(kubectl get deployments -n webapp -l managed-by=webapp-operator --no-headers 2>/dev/null | wc -l)
if [ "$DEPLOY_COUNT" -ge 4 ]; then
  echo "✅ ${DEPLOY_COUNT} Deployments gestionados por el Operator"
  ((PASS++))
else
  echo "❌ Se esperaban al menos 4 Deployments, encontrados: ${DEPLOY_COUNT}"
  ((FAIL++))
fi

# Test 5: Status conditions presentes
CONDITION=$(kubectl get wad webapp-production -n webapp -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
if [ "$CONDITION" = "True" ]; then
  echo "✅ Condición Available=True en webapp-production"
  ((PASS++))
else
  echo "❌ Condición Available no es True: ${CONDITION}"
  ((FAIL++))
fi

# Test 6: RBAC mínimo configurado
if kubectl get clusterrole webapp-operator-manager-role &>/dev/null; then
  echo "✅ ClusterRole del Operator configurado"
  ((PASS++))
else
  echo "❌ ClusterRole no encontrado"
  ((FAIL++))
fi

# Test 7: Finalizer presente
FINALIZER=$(kubectl get wad webapp-production -n webapp -o jsonpath='{.metadata.finalizers[0]}' 2>/dev/null)
if [ "$FINALIZER" = "apps.lab.local/finalizer" ]; then
  echo "✅ Finalizer configurado correctamente"
  ((PASS++))
else
  echo "❌ Finalizer no encontrado: ${FINALIZER}"
  ((FAIL++))
fi

echo ""
echo "========================================="
echo " Resultado: ${PASS} pasaron, ${FAIL} fallaron"
echo "========================================="
```

---

## Solución de Problemas

### Problema 1: El Operator se reinicia con CrashLoopBackOff

**Síntomas:**
```
kubectl get pods -n webapp-operator-system
NAME                                                  READY   STATUS             RESTARTS   AGE
webapp-operator-controller-manager-xxx-xxx            1/2     CrashLoopBackOff   3          2m
```

**Causa:** El webhook de conversión no puede inicializarse porque cert-manager no ha emitido el certificado TLS, o los patches de kustomize para cert-manager no se descomentaron correctamente en `config/default/kustomization.yaml`.

**Solución:**
```bash
# Verificar que cert-manager está operativo
kubectl get pods -n cert-manager

# Verificar si el Certificate fue creado
kubectl get certificate -n webapp-operator-system

# Si no existe, verificar los patches de kustomize
cd ~/k8s-labs/lab06/webapp-operator
cat config/default/kustomization.yaml | grep -A2 certmanager

# Si los patches no están habilitados, corregir y redesplegar
sed -i 's|#- ../certmanager|- ../certmanager|' config/default/kustomization.yaml
make deploy IMG=localhost:5000/webapp-operator:v0.1.0

# Alternativa: si el webhook no es crítico para el lab, deshabilitar temporalmente
# la conversión y usar solo v1alpha1 como storage version
```

### Problema 2: Los Deployments hijos no se crean tras aplicar un WebAppDeployment

**Síntomas:**
```
kubectl get wad -n webapp
NAME                FRONTEND   BACKEND   READY   AGE
webapp-production   3          2         0       2m

kubectl get deployments -n webapp
No resources found in webapp namespace.
```

**Causa:** El controlador no tiene permisos RBAC suficientes para crear Deployments en el namespace `webapp`. Los marcadores `+kubebuilder:rbac` en el controlador no se regeneraron correctamente, o el ClusterRoleBinding no apunta al ServiceAccount correcto.

**Solución:**
```bash
# Verificar los logs del Operator para errores de permisos
kubectl logs -n webapp-operator-system deployment/webapp-operator-controller-manager -c manager | grep -i "forbidden\|unauthorized"

# Verificar el ClusterRole
kubectl describe clusterrole webapp-operator-manager-role | grep -A3 "deployments"

# Si falta el permiso, regenerar manifests y redesplegar
cd ~/k8s-labs/lab06/webapp-operator
make manifests
make deploy IMG=localhost:5000/webapp-operator:v0.1.0

# Verificar que el ServiceAccount tiene el binding correcto
kubectl get clusterrolebinding | grep webapp-operator
kubectl describe clusterrolebinding webapp-operator-manager-rolebinding
```

---

## Limpieza

Para eliminar todos los recursos creados en este laboratorio (ejecutar **solo** si no se necesita el Operator para labs posteriores — **Nota:** el Lab 09 requiere este Operator activo):

```bash
cd ~/k8s-labs/lab06/webapp-operator

# Eliminar instancias de WebAppDeployment
kubectl delete wad --all -n webapp

# Esperar a que los finalizers se procesen
sleep 10

# Desinstalar el Operator (CRD, RBAC, Deployment, Webhooks)
make undeploy

# Eliminar namespace de la aplicación
kubectl delete namespace webapp

# Verificar limpieza
kubectl get crd | grep apps.lab.local
kubectl get namespace webapp-operator-system 2>/dev/null
```

> ⚠️ **Importante:** Si planea continuar con el Lab 09 (políticas OPA/Gatekeeper), **NO ejecute la limpieza**. El Operator debe permanecer activo en el clúster.

---

## Resumen

En este laboratorio se completó el ciclo completo de desarrollo de un Operator de Kubernetes:

| Fase | Resultado |
|------|-----------|
| Scaffolding | Proyecto kubebuilder con dos versiones de API (v1alpha1, v1beta1) |
| Tipos CRD | Esquema OpenAPI v3 con validación, subrecurso status y printcolumns |
| Controlador | Reconciliación con watches, predicates, rate limiting y finalizers |
| Conversion Webhook | Migración transparente entre versiones usando patrón Hub/Spoke |
| Imagen | Publicada en `localhost:5000/webapp-operator:v0.1.0` |
| Despliegue | Operator activo con RBAC mínimo en `webapp-operator-system` |
| Validación | 3 instancias con ciclo completo de creación, actualización y eliminación |

### Conceptos Clave Aplicados

- **Patrón spec/status**: separación clara entre estado deseado y observado
- **Owner References**: garbage collection automática de recursos hijos
- **Finalizers**: lógica de limpieza garantizada antes de la eliminación
- **Controller-runtime**: watches sobre recursos propios y owned, predicates para filtrar eventos
- **Conversion Webhook (Hub/Spoke)**: evolución de APIs sin romper compatibilidad

### Recursos Adicionales

- [Kubebuilder Book](https://book.kubebuilder.io/)
- [controller-runtime documentation](https://pkg.go.dev/sigs.k8s.io/controller-runtime)
- [Kubernetes CRD Documentation](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
- [Operator SDK Best Practices](https://sdk.operatorframework.io/docs/best-practices/)
