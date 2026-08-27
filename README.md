# DocuFlow Infrastructure

Infrastructure as Code for the DocuFlow platform - Docker Compose, Kubernetes, and Terraform.

## Structure

```
docuflow-infra/
├── docker/
│   ├── docker-compose.yml          # Local development stack
│   ├── nginx/                      # Nginx reverse proxy config
│   ├── prometheus/                 # Prometheus config
│   ├── grafana/                    # Grafana dashboards & datasources
│   ├── keycloak/                   # Keycloak realm export
│   ├── postgres/                   # Postgres init scripts
│   └── supervisor/                 # Supervisor configs
├── kubernetes/
│   ├── base/                       # Base K8s manifests
│   │   ├── namespace.yaml
│   │   ├── configmap-secret.yaml
│   │   ├── docuflow-core.yaml
│   │   ├── docuflow-integrations.yaml
│   │   ├── docuflow-ml.yaml
│   │   ├── docuflow-api.yaml
│   │   ├── postgres.yaml
│   │   ├── redis.yaml
│   │   ├── minio.yaml
│   │   └── kafka-zookeeper.yaml
│   └── overlays/
│       ├── dev/                    # Development overlay
│       ├── staging/                # Staging overlay
│       └── prod/                   # Production overlay
├── terraform/
│   ├── modules/
│   │   ├── vpc/                    # VPC, subnets, NAT gateways
│   │   ├── eks/                    # EKS cluster
│   │   └── rds/                    # RDS PostgreSQL
│   └── environments/
│       ├── dev/                    # Development environment
│       ├── staging/                # Staging environment
│       └── prod/                   # Production environment
├── scripts/
│   ├── deploy.sh                   # Deployment script
│   ├── seed-data.sh                # Seed initial data
│   └── backup.sh                   # Backup script
└── .github/workflows/              # CI/CD pipelines
```

## Quick Start (Docker Compose)

```bash
# Start all services
cd docker
docker compose up -d

# View logs
docker compose logs -f docuflow-api

# Stop all services
docker compose down

# Stop and remove volumes
docker compose down -v
```

### Services Available

| Service | URL | Credentials |
|---------|-----|-------------|
| DocuFlow API | http://localhost:8000 | - |
| Filament Admin | http://localhost:8000/admin | - |
| Reverb WebSocket | ws://localhost:8080 | - |
| MinIO Console | http://localhost:9001 | minioadmin/minioadmin |
| RabbitMQ Management | http://localhost:15672 | guest/guest |
| Keycloak | http://localhost:8080 | admin/admin |
| Grafana | http://localhost:3000 | admin/admin |
| Prometheus | http://localhost:9090 | - |

## Kubernetes Deployment

### Prerequisites

- kubectl configured for target cluster
- kustomize installed
- Helm 3.x installed

### Deploy to Dev

```bash
cd kubernetes/overlays/dev
kustomize build | kubectl apply -f -
```

### Deploy to Staging

```bash
cd kubernetes/overlays/staging
kustomize build | kubectl apply -f -
```

### Deploy to Production

```bash
cd kubernetes/overlays/prod
kustomize build | kubectl apply -f -
```

### Verify Deployment

```bash
# Check pod status
kubectl get pods -n docuflow

# Check services
kubectl get svc -n docuflow

# View logs
kubectl logs -n docuflow -l app=docuflow-api -f
```

## Terraform Deployment

### Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured
- S3 bucket for state storage
- DynamoDB table for state locking

### Deploy Dev Environment

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

### Deploy Staging Environment

```bash
cd terraform/environments/staging
terraform init
terraform plan
terraform apply
```

### Deploy Production Environment

```bash
cd terraform/environments/prod
terraform init
terraform plan
terraform apply
```

## CI/CD

All repositories have GitHub Actions workflows:

- **Build**: Compile, test, lint
- **Integration Test**: Run against real dependencies (PostgreSQL, Kafka, etc.)
- **Docker**: Build and push images on tag push
- **Publish**: Publish Maven packages (docuflow-shared) on tag push

### Required Secrets

| Secret | Description |
|--------|-------------|
| `GITHUB_TOKEN` | Auto-provided for package publishing |
| `AWS_ACCESS_KEY_ID` | For Terraform deployments |
| `AWS_SECRET_ACCESS_KEY` | For Terraform deployments |
| `DB_PASSWORD` | Database password for RDS |
| `REDIS_PASSWORD` | Redis auth token |

## Monitoring

### Prometheus Metrics

Each service exposes metrics at `/actuator/prometheus` (Spring Boot) or `/metrics` (Laravel/Python).

### Grafana Dashboards

Pre-configured dashboards in `docker/grafana/dashboards/`:

- DocuFlow Overview
- Document Processing Pipeline
- gRPC Service Metrics
- Infrastructure (K8s, Node, PostgreSQL, Redis)

### Alerting

Configure alerts in Prometheus Alertmanager for:

- High error rates
- Processing pipeline lag
- Resource exhaustion
- Failed webhook deliveries

## Backup & Recovery

### Database Backup

```bash
# Automated via script
./scripts/backup.sh postgres

# Manual
kubectl exec -n docuflow postgres-0 -- pg_dump -U docuflow docuflow > backup.sql
```

### Model Cache Backup

```bash
# Backup ML models
./scripts/backup.sh ml-models
```

### Restore

```bash
# Restore database
kubectl exec -n docuflow postgres-0 -- psql -U docuflow docuflow < backup.sql
```

## Security

### Network Policies

Kubernetes NetworkPolicies restrict inter-service communication:

- Only docuflow-api can reach docuflow-core gRPC
- Only docuflow-core can reach docuflow-ml gRPC
- DocuFlow-integrations can reach external APIs only

### Secrets Management

- Kubernetes secrets for runtime configuration
- External secrets operator for production (AWS Secrets Manager, HashiCorp Vault)
- No secrets in Docker images or git history

### TLS

- Cert-manager for automatic TLS certificates
- mTLS between services via Istio/Linkerd (optional)

## Scaling

### Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: docuflow-api-hpa
  namespace: docuflow
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: docuflow-api
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### KEDA for Event-Driven Scaling

Scale docuflow-core based on Kafka lag:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: docuflow-core-kafka-scaler
  namespace: docuflow
spec:
  scaleTargetRef:
    name: docuflow-core
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka:9092
        consumerGroup: docuflow-core
        topic: docuflow.documents.to-process
        lagThreshold: "10"
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Pods stuck in Pending | Check resource quotas, node capacity, PVC binding |
| gRPC connection refused | Verify service names, ports, network policies |
| ML models not loading | Check PVC mount, model cache directory permissions |
| High memory usage | Increase pod limits, check for memory leaks |

### Debug Commands

```bash
# Port forward for debugging
kubectl port-forward -n docuflow svc/docuflow-core 9090:9090

# Execute into pod
kubectl exec -n docuflow -it docuflow-core-xxx -- /bin/sh

# Check resource usage
kubectl top pods -n docuflow

# Describe problematic pod
kubectl describe pod -n docuflow docuflow-core-xxx
```