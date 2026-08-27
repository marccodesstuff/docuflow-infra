# Terraform dev environment
# docuflow-infra/terraform/environments/dev/main.tf

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
  }

  backend "s3" {
    bucket         = "docuflow-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "docuflow-terraform-locks"
  }
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_id]
    }
  }
}

locals {
  common_tags = {
    Environment = "dev"
    Project     = "docuflow"
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  region             = var.region
  tags               = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name    = "docuflow-dev"
  cluster_version = "1.28"

  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  public_subnet_ids        = module.vpc.public_subnet_ids

  node_groups = {
    general = {
      instance_types     = ["t3.medium"]
      capacity_type      = "ON_DEMAND"
      min_size           = 1
      max_size           = 3
      desired_size       = 2
      disk_size          = 50
      labels = {
        workload = "general"
      }
    }
    ml = {
      instance_types     = ["g5.xlarge"]
      capacity_type      = "SPOT"
      min_size           = 0
      max_size           = 2
      desired_size       = 0
      disk_size          = 100
      labels = {
        workload = "ml"
      }
      taints = [{
        key    = "workload"
        value  = "ml"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = local.common_tags
}

module "rds" {
  source = "../../modules/rds"

  identifier             = "docuflow-dev"
  engine_version         = "16.2"
  instance_class         = "db.t3.medium"
  allocated_storage      = 20
  max_allocated_storage  = 100

  db_subnet_group_name   = module.vpc.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  username = "docuflow"
  password = var.db_password

  backup_retention_period = 1
  multi_az                = false

  vpc_id = module.vpc.vpc_id

  tags = local.common_tags
}

resource "aws_security_group" "rds" {
  name        = "docuflow-dev-rds-sg"
  description = "Security group for RDS dev"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# Elasticache for Redis
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "docuflow-dev-redis"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t3.micro"
  number_cache_clusters      = 1
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token_enabled         = true
  auth_token                 = var.redis_password

  tags = local.common_tags
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "docuflow-dev-redis-subnet"
  subnet_ids = module.vpc.private_subnet_ids

  tags = local.common_tags
}

resource "aws_security_group" "redis" {
  name        = "docuflow-dev-redis-sg"
  description = "Security group for Redis dev"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# S3 bucket for Terraform state and application data
resource "aws_s3_bucket" "app_data" {
  bucket = "docuflow-dev-app-data-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 8
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "redis_password" {
  type      = string
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}