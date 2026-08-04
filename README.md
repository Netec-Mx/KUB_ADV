# Kubernets Avanzado

Curso avanzado para diseñar, evaluar y optimizar redes, accesos externos, scheduling, observabilidad, extensiones y seguridad en clusters Kubernetes en entornos reales.

## Estructura

- `CapituloXX/README.md`: guía de laboratorio por capítulo.

## Lista de laboratorios

### Capítulo 1

- [desplegar y evaluar CNIs (Calico, Cilium)](Capitulo01/README.md#desplegar-y-evaluar-cnis-calico-cilium)
  - Descripción: Desplegar y evaluar CNIs (Calico, Cilium) para comparar su comportamiento en conectividad, rendimiento y aislamiento dentro del cluster.
  - Duración estimada: 29 min

### Capítulo 2

- [implementar Ingress controller y Gateway con certificados gestionados](Capitulo02/README.md#implementar-ingress-controller-y-gateway-con-certificados-gestionados)
  - Descripción: Implementar un Ingress controller y un Gateway con certificados gestionados para exponer servicios mediante terminación TLS segura.
  - Duración estimada: 34 min

### Capítulo 3

- [crear políticas de scheduling y extender comportamiento del scheduler](Capitulo03/README.md#crear-políticas-de-scheduling-y-extender-comportamiento-del-scheduler)
  - Descripción: Crear políticas de scheduling y extender el comportamiento del scheduler mediante affinity, anti-affinity, taints, tolerations y recursos personalizados.
  - Duración estimada: 43 min

### Capítulo 4

- [implementar ELK/EFK y Jaeger para trazabilidad](Capitulo04/README.md#implementar-elkefk-y-jaeger-para-trazabilidad)
  - Descripción: Implementar ELK/EFK y Jaeger para centralizar logs, habilitar tracing distribuido y apoyar el diagnóstico y el análisis de causa raíz.
  - Duración estimada: 43 min

### Capítulo 5

- [desplegar Prometheus, configurar alertas y simular incidentes](Capitulo05/README.md#desplegar-prometheus-configurar-alertas-y-simular-incidentes)
  - Descripción: Desplegar Prometheus, configurar reglas de alerta y simular incidentes para validar la detección de degradaciones y la respuesta operativa.
  - Duración estimada: 43 min

### Capítulo 6

- [desarrollar un Operator básico y desplegar CRDs](Capitulo06/README.md#desarrollar-un-operator-básico-y-desplegar-crds)
  - Descripción: Desarrollar un Operator básico y desplegar CRDs para extender Kubernetes y automatizar operaciones aplicacionales.
  - Duración estimada: 43 min

### Capítulo 7

- [construir y publicar charts; integrar en pipeline CI](Capitulo07/README.md#construir-y-publicar-charts-integrar-en-pipeline-ci)
  - Descripción: Construir y publicar charts de Helm e integrarlos en un pipeline CI para validar despliegues reproducibles, versionados y con estrategias de rollback.
  - Duración estimada: 43 min

### Capítulo 8

- [aplicar hardening, políticas y auditoría en cluster](Capitulo08/README.md#aplicar-hardening-políticas-y-auditoría-en-cluster)
  - Descripción: Aplicar hardening, políticas de seguridad y auditoría en el cluster para proteger el plano de control, los nodos y las cargas de trabajo.
  - Duración estimada: 43 min

### Capítulo 9

- [crear políticas OPA/Gatekeeper y validar enforcement](Capitulo09/README.md#crear-políticas-opagatekeeper-y-validar-enforcement)
  - Descripción: Crear políticas OPA/Gatekeeper y validar su enforcement para establecer controles declarativos de gobernanza y cumplimiento.
  - Duración estimada: 43 min

### Capítulo 10

- [diseñar y validar un plan de DR multi-cluster](Capitulo10/README.md#diseñar-y-validar-un-plan-de-dr-multi-cluster)
  - Descripción: Diseñar y validar un plan de recuperación ante desastres multi-cluster que contemple alta disponibilidad, backups y recuperación.
  - Duración estimada: 41 min

## Flujo de colaboración

- Trabajar en `changes_course`.
- Crear Pull Request hacia `main`.
- Merge por `Squash and merge`.
