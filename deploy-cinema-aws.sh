#!/usr/bin/env bash
set -euo pipefail

# Configurazione
REGION="${REGION:-eu-west-1}"
SKIP_ECR="${SKIP_ECR:-false}"
SKIP_ECS="${SKIP_ECS:-false}"
SKIP_INFRASTRUCTURE="${SKIP_INFRASTRUCTURE:-false}"
SKIP_VPC_ENDPOINTS="${SKIP_VPC_ENDPOINTS:-false}"
CLEANUP="${CLEANUP:-false}"
CREATE_CODEPIPELINE="${CREATE_CODEPIPELINE:-false}"
CODEBUILD="${CODEBUILD:-false}"

if [ "$CODEBUILD" = "true" ]; then
    AWS_ACCOUNT_ID=${ACCOUNT_ID}
else
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi

if [ ! -f "aws-resources.json" ]; then
    echo "{}" > aws-resources.json
fi

CLUSTER_NAME="cinema-cluster"
VPC_NAME="cinema-vpc"
REPO_PREFIX="cinema"

declare -A SERVICES=(
    ["api-gateway"]="8080"
    ["movies-service"]="3000"
    ["cinema-catalog-service"]="3001"
    ["booking-service"]="3003"
    ["payment-service"]="3002"
    ["notification-service"]="3004"
)

function print_header {
    local title="$1"
    echo ""
    echo "============================================================"
    echo "  $title"
    echo "============================================================"
    echo ""
}

function codebuild_log {
    local message="$1"
    if [ "$CODEBUILD" = "true" ]; then
        echo "[CodeBuild] $message"
    else
        echo "$message"
    fi
}

function create_codepipeline_role {
    print_step "Creating CodePipeline IAM Role" "Setting up role for CI/CD pipeline..."
    
    local role_name="cinema-codepipeline-role"
    local policy_name="cinema-codepipeline-policy"
    
    cat > codepipeline-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    cat > codepipeline-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketVersioning",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::cinema-pipeline-artifacts-${AWS_ACCOUNT_ID}",
        "arn:aws:s3:::cinema-pipeline-artifacts-${AWS_ACCOUNT_ID}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "arn:aws:codebuild:${REGION}:${AWS_ACCOUNT_ID}:project/cinema-microservices-build"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRole"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/cinema-codebuild-role"
    }
  ]
}
EOF

    if ! aws iam get-role --role-name "$role_name" --region "$REGION" >/dev/null 2>&1; then
        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document file://codepipeline-trust-policy.json \
            --description "Role for Cinema Microservices CodePipeline" \
            --region "$REGION" >/dev/null
        print_success "CodePipeline role $role_name created"
    else
        echo "   Role $role_name already exists"
    fi

    aws iam update-assume-role-policy \
        --role-name "$role_name" \
        --policy-document file://codepipeline-trust-policy.json \
        --region "$REGION" >/dev/null

    aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "$policy_name" \
        --policy-document file://codepipeline-policy.json \
        --region "$REGION" >/dev/null

    print_success "CodePipeline policy attached to role"

    rm -f codepipeline-trust-policy.json codepipeline-policy.json

    local role_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${role_name}"
    echo "   CodePipeline Role ARN: $role_arn"
    
    if [ -f "aws-resources.json" ]; then
        jq --arg arn "$role_arn" '.CodePipelineRole = $arn' aws-resources.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
    else
        echo "{\"CodePipelineRole\": \"$role_arn\"}" > aws-resources.json
    fi
    
    print_success "CodePipeline role setup completed"
}

function ensure_pipeline_bucket {
    local bucket="cinema-pipeline-artifacts-$AWS_ACCOUNT_ID"
    if ! aws s3 ls "s3://$bucket" --region "$REGION" >/dev/null 2>&1; then
        echo "   Creating pipeline artifact bucket: $bucket"
        aws s3api create-bucket \
            --bucket "$bucket" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
        print_success "Pipeline artifact bucket $bucket created"
    else
        echo "   Pipeline artifact bucket already exists: $bucket"
    fi
    
    if [ -f "aws-resources.json" ]; then
        jq --arg bucket "$bucket" '.CodePipelineArtifactBucket = $bucket' aws-resources.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
    else
        echo "{\"CodePipelineArtifactBucket\": \"$bucket\"}" > aws-resources.json
    fi
}

function create_codepipeline {
    print_step "Creating CodePipeline" "Setting up CI/CD pipeline..."
    
    local pipeline_name="cinema-microservices-pipeline"
    local build_project_name="cinema-microservices-build"
    local artifact_bucket="cinema-pipeline-artifacts-$AWS_ACCOUNT_ID"
    local role_arn="arn:aws:iam::$AWS_ACCOUNT_ID:role/cinema-codepipeline-role"
    
    if ! aws codebuild get-project --name "$build_project_name" --region "$REGION" >/dev/null 2>&1; then
        echo "   Creating CodeBuild project: $build_project_name"
        
        cat > buildspec-codepipeline.yml << EOF
version: 0.2

env:
  variables:
    REGION: "eu-west-1"
    CLUSTER_NAME: "cinema-cluster"
    ACCOUNT_ID: "$AWS_ACCOUNT_ID"
    CODEBUILD: "true"

phases:
  install:
    runtime-versions:
      docker: 20
    commands:
      - echo "Installing dependencies..."
      - apt-get update -y
      - apt-get install -y jq awscli
      - echo "Dependencies installed"
  
  pre_build:
    commands:
      - echo "Logging into Amazon ECR..."
      - aws ecr get-login-password --region \$REGION | docker login --username AWS --password-stdin \$ACCOUNT_ID.dkr.ecr.\$REGION.amazonaws.com
      - echo "Logged into ECR"
      - echo "Setting up environment for deployment..."
      - export AWS_DEFAULT_REGION=\$REGION
      - echo "Environment configured for region: \$REGION"
  
  build:
    commands:
      - echo "Running deployment script..."
      - chmod +x deploy-cinema-aws.sh
      - bash deploy-cinema-aws.sh
      - echo "Deployment completed successfully!"
  
  post_build:
    commands:
      - echo "Build & Deploy finished!"
      - echo "Checking deployment status..."
      - if [ -f "aws-resources.json" ]; then
          echo "Deployment resources:"
          cat aws-resources.json
        fi
      - echo "CI/CD pipeline completed successfully!"

artifacts:
  files:
    - "aws-resources.json"
    - "deploy-cinema-aws.sh"
    - "README.md"
  discard-paths: no
EOF

        aws codebuild create-project \
            --name "$build_project_name" \
            --description "Build project for Cinema Microservices" \
            --service-role "arn:aws:iam::$AWS_ACCOUNT_ID:role/cinema-codebuild-role" \
            --artifacts '{
                "type": "CODEPIPELINE"
            }' \
            --environment '{
                "type": "LINUX_CONTAINER",
                "image": "aws/codebuild/standard:5.0",
                "computeType": "BUILD_GENERAL1_MEDIUM",
                "environmentVariables": [
                    {
                        "name": "REGION",
                        "value": "eu-west-1"
                    },
                    {
                        "name": "ACCOUNT_ID",
                        "value": "'$AWS_ACCOUNT_ID'"
                    },
                    {
                        "name": "CLUSTER_NAME",
                        "value": "cinema-cluster"
                    },
                    {
                        "name": "CODEBUILD",
                        "value": "true"
                    }
                ]
            }' \
            --source '{
                "type": "CODEPIPELINE",
                "buildspec": "buildspec-codepipeline.yml"
            }' \
            --region "$REGION" >/dev/null
        
        print_success "CodeBuild project $build_project_name created"
        rm -f buildspec-codepipeline.yml
    else
        echo "   CodeBuild project $build_project_name already exists"
    fi
    
    print_success "CodePipeline setup completed"
    echo "   Pipeline Name: $pipeline_name"
    echo "   Build Project: $build_project_name"
    echo "   Artifact Bucket: $artifact_bucket"
    echo "   Role ARN: $role_arn"
    echo ""
}

function print_step {
    local step="$1"
    local description="$2"
    echo "STEP: $step"
    echo "   $description"
}

function print_success {
    local message="$1"
    echo "SUCCESS: $message"
}

function print_error {
    local message="$1"
    echo "ERROR: $message"
}

function check_aws_cli {
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        print_error "AWS CLI non configurato. Esegui 'aws configure' prima di continuare."
        exit 1
    fi
}

function deploy_ecr {
    print_header "DEPLOYING TO ECR (Elastic Container Registry)"
    
    echo "Authenticating with ECR..."
    aws ecr get-login-password --region "$REGION" | \
        docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
    
    if [ $? -ne 0 ]; then
        print_error "ECR login failed!"
        return 1
    fi
    print_success "ECR login successful!"
    
    for service in "${!SERVICES[@]}"; do
        local port="${SERVICES[$service]}"
        local repo_name="$REPO_PREFIX-$service"
        
        print_step "Processing $service" "Creating repository and pushing image..."
        
        if [ ! -d "$service" ]; then
            echo "WARNING:  Directory $service non trovata, skipping..."
            continue
        fi
        
        if [ ! -f "$service/Dockerfile" ]; then
            echo "WARNING:  Dockerfile non trovato in $service, skipping..."
            continue
        fi
        
        if ! aws ecr describe-repositories --repository-names "$repo_name" --region "$REGION" >/dev/null 2>&1; then
            echo "   Creating ECR repository: $repo_name"
            aws ecr create-repository --repository-name "$repo_name" \
                --image-scanning-configuration scanOnPush=true --region "$REGION" >/dev/null
        else
            echo "   Repository $repo_name already exists"
        fi
        
        local image_uri="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$repo_name:latest"
        
        docker build -t "$image_uri" "./$service" >/dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            print_error "Build failed for $service"
            continue
        fi
        
        docker push "$image_uri" >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "$service deployed to ECR: $image_uri"
        else
            print_error "Push failed for $service"
        fi
    done
    
    return 0
}

function create_service_discovery_services {
    print_step "Creating Service Discovery Services" "Creating service registries for microservices..."
    
    local namespace_id=$(aws servicediscovery list-namespaces --region "$REGION" \
        --query 'Namespaces[?Name==`cinema-cluster.local`].Id' --output text | tr -d '\r\n' | head -n1 | awk '{print $1}')
    
    if [ -z "$namespace_id" ] || [ "$namespace_id" = "None" ] || [ "$namespace_id" = "null" ]; then
        print_error "Service Discovery namespace not found. Please run full deployment first."
        return 1
    fi
    
    echo "  Using existing namespace: $namespace_id"
    
    declare -A SERVICE_DISCOVERY_ARNS
    
    local discovery_services=("movies-service" "cinema-catalog-service" "booking-service" "payment-service" "notification-service")
    
    for service in "${discovery_services[@]}"; do
        echo "  Processing Service Discovery service for $service..."
        echo "    Using namespace ID: $namespace_id"
        
        local existing_service_arn=$(aws servicediscovery list-services --region "$REGION" \
            --query "Services[?Name=='$service'].Arn" --output text 2>/dev/null || echo "")
        
        if [ -n "$existing_service_arn" ] && [ "$existing_service_arn" != "None" ]; then
            SERVICE_DISCOVERY_ARNS["$service"]="$existing_service_arn"
            echo "    SUCCESS: Using existing Service Discovery service: $existing_service_arn"
        else
            echo "    Creating new Service Discovery service..."
            local sd_service_arn=$(aws servicediscovery create-service \
                --name "$service" \
                --namespace-id "$namespace_id" \
                --dns-config "NamespaceId=$namespace_id,RoutingPolicy=WEIGHTED,DnsRecords=[{Type=A,TTL=60}]" \
                --region "$REGION" \
                --query 'Service.Arn' --output text 2>/dev/null || echo "")
            
            if [ -n "$sd_service_arn" ] && [ "$sd_service_arn" != "None" ]; then
                SERVICE_DISCOVERY_ARNS["$service"]="$sd_service_arn"
                echo "    SUCCESS: Created Service Discovery service: $sd_service_arn"
            else
                echo "    ERROR: Failed to create Service Discovery service for $service"
                echo "    Debug - Namespace ID: '$namespace_id'"
                echo "    Debug - Service ARN: '$sd_service_arn'"
                return 1
            fi
        fi
    done
    
    echo "  Saving Service Discovery ARNs to temporary file..."
    
    cat > service-discovery-arns.json <<EOF
{
  "ServiceDiscoveryARNs": {
EOF
    
    local first=true
    for service in "${discovery_services[@]}"; do
        if [ -n "${SERVICE_DISCOVERY_ARNS[$service]}" ]; then
            echo "    Adding ARN for $service: ${SERVICE_DISCOVERY_ARNS[$service]}"
            if [ "$first" = true ]; then
                echo "    \"$service\": \"${SERVICE_DISCOVERY_ARNS[$service]}\"" >> service-discovery-arns.json
                first=false
            else
                echo "    ,\"$service\": \"${SERVICE_DISCOVERY_ARNS[$service]}\"" >> service-discovery-arns.json
            fi
        fi
    done
    
    echo "  }" >> service-discovery-arns.json
    echo "}" >> service-discovery-arns.json
    
    if [ -f "aws-resources.json" ]; then
        echo "  Merging Service Discovery ARNs into aws-resources.json..."
        jq '. * input' aws-resources.json service-discovery-arns.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
        rm -f service-discovery-arns.json
    fi
    
    print_success "Service Discovery services created successfully"
    return 0
}

function create_improved_target_group {
    print_step "Creating Improved Target Group" "Setting up target group for API Gateway..." >&2
    
    local vpc_id="$1"
    
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "null" ]; then
        echo "  ERROR: VPC ID is empty or null: $vpc_id" >&2
        print_error "Invalid VPC ID provided" >&2
        return 1
    fi
    
    local vpc_exists=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --region "$REGION" --query 'Vpcs[0].State' --output text 2>/dev/null || echo "invalid")
    if [ "$vpc_exists" != "available" ]; then
        echo "  ERROR: VPC $vpc_id does not exist or is not available (State: $vpc_exists)" >&2
        print_error "VPC not found or not available" >&2
        return 1
    fi
    
    echo "  VPC ID validated: $vpc_id (State: $vpc_exists)" >&2
    
    local existing_tg=$(aws elbv2 describe-target-groups \
        --names cinema-api-tg --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$existing_tg" != "None" ] && [ -n "$existing_tg" ]; then
        echo "  Deleting existing target group..." >&2
        aws elbv2 delete-target-group --target-group-arn "$existing_tg" --region "$REGION" >/dev/null 2>&1 || true
        sleep 10
    fi
    
    echo "  Creating target group with VPC ID: $vpc_id" >&2
    local tg_arn=$(aws elbv2 create-target-group \
        --name cinema-api-tg \
        --protocol HTTP \
        --port 8080 \
        --vpc-id "$vpc_id" \
        --target-type ip \
        --health-check-protocol HTTP \
        --health-check-path "/" \
        --health-check-port 8080 \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 15 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --matcher '{"HttpCode":"200"}' \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>&1)
    
    local create_exit_code=$?
    
    if [ $create_exit_code -ne 0 ]; then
        echo "  ERROR: Target Group creation failed with exit code: $create_exit_code" >&2
        echo "  ERROR: AWS CLI output: $tg_arn" >&2
        print_error "Failed to create Target Group" >&2
        return 1
    fi
    
    if [ -z "$tg_arn" ] || [ "$tg_arn" = "null" ] || [[ "$tg_arn" == *"error"* ]] || [[ "$tg_arn" == *"Parameter validation failed"* ]]; then
        echo "  ERROR: Target Group ARN is empty or contains error: $tg_arn" >&2
        print_error "Failed to create Target Group" >&2
        return 1
    fi
    
    tg_arn=$(echo "$tg_arn" | tr -d '\r\n' | grep -o 'arn:aws:elasticloadbalancing:[^[:space:]]*' | head -n1)
    
    if [ -z "$tg_arn" ] || [ "$tg_arn" = "null" ]; then
        echo "  ERROR: Failed to extract valid Target Group ARN from: $tg_arn" >&2
        print_error "Failed to create Target Group" >&2
        return 1
    fi
    
    print_success "Target Group created: $tg_arn" >&2
    echo "$tg_arn"
}

function create_api_gateway_task_definition {
    local service="api-gateway"
    local port="8080"
    local image_uri="$1"
    
    cat > "task-definition-$service.json" << EOF
{
    "family": "$service",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
    "taskRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "$service",
            "image": "$image_uri",
            "portMappings": [
                {
                    "containerPort": $port,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "environment": [
                {
                    "name": "PORT",
                    "value": "$port"
                },
                {
                    "name": "NODE_ENV",
                    "value": "production"
                },
                {
                    "name": "MOVIES_SERVICE_URL",
                    "value": "http://movies-service.cinema-cluster.local:3000"
                },
                {
                    "name": "CINEMA_CATALOG_SERVICE_URL", 
                    "value": "http://cinema-catalog-service.cinema-cluster.local:3001"
                },
                {
                    "name": "BOOKING_SERVICE_URL",
                    "value": "http://booking-service.cinema-cluster.local:3003"
                },
                {
                    "name": "PAYMENT_SERVICE_URL",
                    "value": "http://payment-service.cinema-cluster.local:3002"
                },
                {
                    "name": "NOTIFICATION_SERVICE_URL",
                    "value": "http://notification-service.cinema-cluster.local:3004"
                }
            ],
            "healthCheck": {
                "command": [
                    "CMD-SHELL",
                "wget --no-verbose --tries=1 --spider http://localhost:$port/ || exit 1"
                ],
                "interval": 30,
                "timeout": 10,
                "retries": 3,
                "startPeriod": 120
            },
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/$service",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF
}

function check_existing_infrastructure {
    print_step "Checking Existing Infrastructure" "Verifying what can be reused..."
    
    local existing_vpc=$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[?Tags[?Key==`Name` && Value==`cinema-vpc`]].VpcId' --output text | tr -d '\r\n' | head -n1)
    if [ -n "$existing_vpc" ] && [ "$existing_vpc" != "None" ]; then
        echo "  Found existing VPC: $existing_vpc" >&2
        echo "$existing_vpc" > /tmp/existing_vpc.txt
    else
        echo "  No existing VPC found" >&2
        rm -f /tmp/existing_vpc.txt
    fi
    
    local existing_alb=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[?LoadBalancerName==`cinema-alb`].LoadBalancerArn' --output text | tr -d '\r\n' | head -n1)
    if [ -n "$existing_alb" ] && [ "$existing_alb" != "None" ]; then
        echo "  Found existing ALB: $existing_alb" >&2
        echo "$existing_alb" > /tmp/existing_alb.txt
    else
        echo "  No existing ALB found" >&2
        rm -f /tmp/existing_alb.txt
    fi
    
    local existing_tg=$(aws elbv2 describe-target-groups --names cinema-api-tg --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    if [ -n "$existing_tg" ] && [ "$existing_tg" != "None" ] && [ "$existing_tg" != "null" ]; then
        echo "  Found existing Target Group: $existing_tg" >&2
        echo "$existing_tg" > /tmp/existing_tg.txt
    else
        echo "  No existing Target Group found" >&2
        rm -f /tmp/existing_tg.txt
    fi
    
    local existing_cluster=$(aws ecs describe-clusters --clusters cinema-cluster --region "$REGION" --query 'clusters[0].status' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    if [ "$existing_cluster" = "ACTIVE" ]; then
        echo "  Found existing ECS Cluster: cinema-cluster" >&2
        echo "cinema-cluster" > /tmp/existing_cluster.txt
    else
        echo "  No existing ECS Cluster found" >&2
        rm -f /tmp/existing_cluster.txt
    fi
    
    print_success "Infrastructure check completed" >&2
}

function deploy_ecs_infrastructure {
    print_header "CREATING ECS INFRASTRUCTURE"
    
    check_existing_infrastructure
    
    local vpc_id
    if [ -f /tmp/existing_vpc.txt ]; then
        vpc_id=$(cat /tmp/existing_vpc.txt)
        print_success "Reusing existing VPC: $vpc_id" >&2
    else
        echo "Creating VPC..."
        vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
            --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
            --region "$REGION" --query 'Vpc.VpcId' --output text | tr -d '\r\n')
        print_success "VPC created: $vpc_id" >&2
    fi
    
    if [ $? -eq 0 ]; then
        print_success "VPC created: $vpc_id"
    else
        print_error "VPC creation failed"
        return 1
    fi
    
    echo "Enabling DNS support..."
    aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support --region "$REGION" >/dev/null
    aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames --region "$REGION" >/dev/null
    print_success "DNS support and hostnames enabled"
    
    local igw_id
    local existing_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --region "$REGION" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    
    if [ -n "$existing_igw" ] && [ "$existing_igw" != "None" ]; then
        igw_id="$existing_igw"
        print_success "Reusing existing Internet Gateway: $igw_id" >&2
    else
        print_step "Creating Internet Gateway" "Setting up internet connectivity..."
        igw_id=$(aws ec2 create-internet-gateway \
            --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cinema-igw}]" \
            --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text | tr -d '\r\n')
        
        aws ec2 attach-internet-gateway --vpc-id "$vpc_id" --internet-gateway-id "$igw_id" --region "$REGION" >/dev/null
        print_success "Internet Gateway created and attached: $igw_id" >&2
    fi
    
    local public_subnet_1_id public_subnet_2_id private_subnet_id
    
    local existing_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_subnets" ] && [ "$existing_subnets" != "None" ]; then
        public_subnet_1_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=cinema-public-subnet-1" --region "$REGION" --query 'Subnets[0].SubnetId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
        public_subnet_2_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=cinema-public-subnet-2" --region "$REGION" --query 'Subnets[0].SubnetId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
        private_subnet_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=cinema-private-subnet" --region "$REGION" --query 'Subnets[0].SubnetId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
        
        if [ -n "$public_subnet_1_id" ] && [ -n "$public_subnet_2_id" ] && [ -n "$private_subnet_id" ]; then
            print_success "Reusing existing subnets - Public1: $public_subnet_1_id, Public2: $public_subnet_2_id, Private: $private_subnet_id" >&2
        else
            echo "Creating subnets..."
            public_subnet_1_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.1.0/24 \
                --availability-zone "${REGION}a" \
                --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-public-subnet-1}]" \
                --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
            
            public_subnet_2_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.2.0/24 \
                --availability-zone "${REGION}b" \
                --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-public-subnet-2}]" \
                --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
            
            private_subnet_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.3.0/24 \
                --availability-zone "${REGION}c" \
                --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-private-subnet}]" \
                --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
            
            aws ec2 modify-subnet-attribute --subnet-id "$public_subnet_1_id" --map-public-ip-on-launch --region "$REGION"
            aws ec2 modify-subnet-attribute --subnet-id "$public_subnet_2_id" --map-public-ip-on-launch --region "$REGION"
            
            print_success "Subnets created - Public1: $public_subnet_1_id, Public2: $public_subnet_2_id, Private: $private_subnet_id" >&2
        fi
    else
        echo "Creating subnets..."
        public_subnet_1_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.1.0/24 \
            --availability-zone "${REGION}a" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-public-subnet-1}]" \
            --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
        
        public_subnet_2_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.2.0/24 \
            --availability-zone "${REGION}b" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-public-subnet-2}]" \
            --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
        
        private_subnet_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block 10.0.3.0/24 \
            --availability-zone "${REGION}c" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cinema-private-subnet}]" \
            --region "$REGION" --query 'Subnet.SubnetId' --output text | tr -d '\r\n')
        
        aws ec2 modify-subnet-attribute --subnet-id "$public_subnet_1_id" --map-public-ip-on-launch --region "$REGION"
        aws ec2 modify-subnet-attribute --subnet-id "$public_subnet_2_id" --map-public-ip-on-launch --region "$REGION"
        
        print_success "Subnets created - Public1: $public_subnet_1_id, Public2: $public_subnet_2_id, Private: $private_subnet_id" >&2
    fi
    
    local nat_gateway_id
    local existing_nat=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" --region "$REGION" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    
    if [ -n "$existing_nat" ] && [ "$existing_nat" != "None" ]; then
        nat_gateway_id="$existing_nat"
        print_success "Reusing existing NAT Gateway: $nat_gateway_id" >&2
    else
        print_step "Creating NAT Gateway" "Setting up NAT Gateway for outbound internet access..."
        local nat_eip=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text | tr -d '\r\n')
        nat_gateway_id=$(aws ec2 create-nat-gateway --subnet-id "$public_subnet_1_id" --allocation-id "$nat_eip" \
            --region "$REGION" --query 'NatGateway.NatGatewayId' --output text | tr -d '\r\n')
        
        echo "  Waiting for NAT Gateway to be available..."
        aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat_gateway_id" --region "$REGION" >/dev/null
        
        print_success "NAT Gateway created: $nat_gateway_id" >&2
    fi
    
    local route_table_id private_route_table_id
    
    local existing_public_rt=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=cinema-public-rt" --region "$REGION" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    local existing_private_rt=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=cinema-private-rt" --region "$REGION" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    
    if [ -n "$existing_public_rt" ] && [ -n "$existing_private_rt" ] && [ "$existing_public_rt" != "None" ] && [ "$existing_private_rt" != "None" ]; then
        route_table_id="$existing_public_rt"
        private_route_table_id="$existing_private_rt"
        print_success "Reusing existing Route Tables - Public: $route_table_id, Private: $private_route_table_id" >&2
    else
        print_step "Creating Route Table" "Setting up internet routing..."
        route_table_id=$(aws ec2 create-route-table --vpc-id "$vpc_id" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cinema-public-rt}]" \
            --region "$REGION" --query 'RouteTable.RouteTableId' --output text | tr -d '\r\n')
        
        aws ec2 create-route --route-table-id "$route_table_id" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw_id" --region "$REGION" >/dev/null
        
        aws ec2 associate-route-table --subnet-id "$public_subnet_1_id" --route-table-id "$route_table_id" --region "$REGION" >/dev/null
        aws ec2 associate-route-table --subnet-id "$public_subnet_2_id" --route-table-id "$route_table_id" --region "$REGION" >/dev/null
        
        private_route_table_id=$(aws ec2 create-route-table --vpc-id "$vpc_id" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cinema-private-rt}]" \
            --region "$REGION" --query 'RouteTable.RouteTableId' --output text | tr -d '\r\n')
        
        aws ec2 create-route --route-table-id "$private_route_table_id" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat_gateway_id" --region "$REGION" >/dev/null
        
        aws ec2 associate-route-table --subnet-id "$private_subnet_id" --route-table-id "$private_route_table_id" --region "$REGION" >/dev/null
        
        print_success "Route tables configured for internet access (public) and NAT Gateway (private)" >&2
    fi
    
    local sg_id
    local existing_sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=cinema-sg" "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | tr -d '\r\n' | head -n1)
    
    if [ -n "$existing_sg" ] && [ "$existing_sg" != "None" ]; then
        sg_id="$existing_sg"
        print_success "Reusing existing Security Group: $sg_id" >&2
    else
        print_step "Creating Security Group" "Setting up network security..."
        sg_id=$(aws ec2 create-security-group --group-name cinema-sg \
            --description "Security group for cinema microservices" --vpc-id "$vpc_id" \
            --region "$REGION" --query 'GroupId' --output text | tr -d '\r\n')
        
        aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
        aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
        
        for port in "${SERVICES[@]}"; do
            aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port "$port" --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
        done
        
        print_success "Security Group created: $sg_id" >&2
    fi
    
    local alb_arn
    if [ -f /tmp/existing_alb.txt ]; then
        alb_arn=$(cat /tmp/existing_alb.txt)
        print_success "Reusing existing ALB: $alb_arn" >&2
    else
        echo "Creating Application Load Balancer..."
        alb_arn=$(aws elbv2 create-load-balancer \
            --name cinema-alb \
            --subnets "$public_subnet_1_id" "$public_subnet_2_id" \
            --security-groups "$sg_id" \
            --scheme internet-facing \
            --type application \
            --region "$REGION" \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | tr -d '\r\n' || echo "")
        
        if [ -z "$alb_arn" ] || [ "$alb_arn" = "null" ]; then
            print_error "Failed to create ALB"
            return 1
        fi
        
        print_success "ALB created: $alb_arn" >&2
    fi
    
    local tg_arn
    if [ -f /tmp/existing_tg.txt ]; then
        tg_arn=$(cat /tmp/existing_tg.txt)
        print_success "Reusing existing Target Group: $tg_arn" >&2
    else
        tg_arn=$(create_improved_target_group "$vpc_id")
    fi
    
    if [ -z "$tg_arn" ] || [ "$tg_arn" = "null" ]; then
        print_error "Failed to create Target Group"
        return 1
    fi
    
    print_success "Target Group created: $tg_arn"
    
    print_step "Creating Listener" "Forwarding traffic to target group..."
    aws elbv2 create-listener \
        --load-balancer-arn "$alb_arn" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$tg_arn" \
        --region "$REGION" >/dev/null
    
    print_success "Listener created on port 80"
    
    if [ -f /tmp/existing_cluster.txt ]; then
        print_success "Reusing existing ECS Cluster: $CLUSTER_NAME" >&2
    else
        print_step "Creating ECS Cluster" "Setting up container orchestration..."
        aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$REGION" >/dev/null
        print_success "ECS Cluster created: $CLUSTER_NAME" >&2
    fi
    
    create_ecs_role
    
    local namespace_id
    local existing_namespace=$(aws servicediscovery list-namespaces --region "$REGION" \
        --query 'Namespaces[?Name==`cinema-cluster.local`].Id' --output text | tr -d '\r\n' | head -n1 | awk '{print $1}')
    
    if [ -n "$existing_namespace" ] && [ "$existing_namespace" != "None" ]; then
        namespace_id="$existing_namespace"
        print_success "Reusing existing Service Discovery namespace: $namespace_id" >&2
    else
        print_step "Creating Service Discovery" "Setting up Cloud Map namespace..."
        local operation_id=$(aws servicediscovery create-private-dns-namespace \
            --name "cinema-cluster.local" \
            --vpc "$vpc_id" \
            --description "Service discovery for cinema microservices" \
            --region "$REGION" \
            --query 'OperationId' --output text)
        
        echo "  Waiting for namespace creation..."
        local operation_status="PENDING"
        while [ "$operation_status" = "PENDING" ]; do
            operation_status=$(aws servicediscovery get-operation --operation-id "$operation_id" --region "$REGION" --query 'Operation.Status' --output text)
            echo "    Operation status: $operation_status"
            sleep 5
        done
        
        if [ "$operation_status" = "SUCCESS" ]; then
            namespace_id=$(aws servicediscovery list-namespaces --region "$REGION" \
                --query 'Namespaces[?Name==`cinema-cluster.local`].Id' --output text | tr -d '\r\n' | head -n1 | awk '{print $1}')
        else
            print_error "Service Discovery namespace creation failed"
            return 1
        fi
    fi
    
    if [ -z "$namespace_id" ] || [ "$namespace_id" = "None" ] || [ "$namespace_id" = "null" ]; then
        print_error "Failed to get valid namespace ID"
        return 1
    fi
    
    print_success "Service Discovery namespace created: $namespace_id"
    
    print_step "Creating Service Discovery Services" "Creating service registries for microservices..."
        
        declare -A SERVICE_DISCOVERY_ARNS
        
        local discovery_services=("movies-service" "cinema-catalog-service" "booking-service" "payment-service" "notification-service")
        
        for service in "${discovery_services[@]}"; do
            echo "  Creating Service Discovery service for $service..."
            echo "    Using namespace ID: $namespace_id"
            
            local existing_sd_service=$(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$namespace_id" --region "$REGION" \
                --query "Services[?Name=='$service'].Arn" --output text | tr -d '\r\n' | head -n1)
            
            if [ -n "$existing_sd_service" ] && [ "$existing_sd_service" != "None" ]; then
                SERVICE_DISCOVERY_ARNS["$service"]="$existing_sd_service"
                echo "    SUCCESS: Reusing existing Service Discovery service: $existing_sd_service"
            else
                local sd_service_arn=$(aws servicediscovery create-service \
                    --name "$service" \
                    --namespace-id "$namespace_id" \
                    --dns-config "NamespaceId=$namespace_id,RoutingPolicy=WEIGHTED,DnsRecords=[{Type=A,TTL=60}]" \
                    --region "$REGION" \
                    --query 'Service.Arn' --output text 2>/dev/null || echo "")
                
                if [ -n "$sd_service_arn" ] && [ "$sd_service_arn" != "None" ]; then
                    SERVICE_DISCOVERY_ARNS["$service"]="$sd_service_arn"
                    echo "    SUCCESS: Created Service Discovery service: $sd_service_arn"
                else
                    echo "    ERROR: Failed to create Service Discovery service for $service"
                    echo "    Debug - Namespace ID: '$namespace_id'"
                    echo "    Debug - Service ARN: '$sd_service_arn'"
                    return 1
                fi
            fi
        done
        
        echo "  Saving Service Discovery ARNs to temporary file..."
        
        cat > service-discovery-arns.json <<EOF
{
  "ServiceDiscoveryARNs": {
EOF
        
        local first=true
        for service in "${discovery_services[@]}"; do
            if [ -n "${SERVICE_DISCOVERY_ARNS[$service]}" ]; then
                echo "    Adding ARN for $service: ${SERVICE_DISCOVERY_ARNS[$service]}"
                if [ "$first" = true ]; then
                    echo "    \"$service\": \"${SERVICE_DISCOVERY_ARNS[$service]}\"" >> service-discovery-arns.json
                    first=false
                else
                    echo "    ,\"$service\": \"${SERVICE_DISCOVERY_ARNS[$service]}\"" >> service-discovery-arns.json
                fi
            fi
        done
        
        echo "  }" >> service-discovery-arns.json
        echo "}" >> service-discovery-arns.json
        
        print_success "Service Discovery services created successfully"
    
    if [ "$SKIP_VPC_ENDPOINTS" != "true" ]; then
        local existing_endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || echo "")
        
        if [ -n "$existing_endpoints" ] && [ "$existing_endpoints" != "None" ]; then
            print_success "Reusing existing VPC Endpoints: $existing_endpoints" >&2
        else
            create_vpc_endpoints
        fi
    else
        echo "WARNING:  Skipping VPC Endpoints creation"
    fi
    
    local clean_vpc_id=$(echo "$vpc_id" | tr -d '\r\n')
    local clean_igw_id=$(echo "$igw_id" | tr -d '\r\n')
    local clean_public_subnet_1_id=$(echo "$public_subnet_1_id" | tr -d '\r\n')
    local clean_public_subnet_2_id=$(echo "$public_subnet_2_id" | tr -d '\r\n')
    local clean_private_subnet_id=$(echo "$private_subnet_id" | tr -d '\r\n')
    local clean_nat_gateway_id=$(echo "$nat_gateway_id" | tr -d '\r\n')
    local clean_nat_eip=$(echo "$nat_eip" | tr -d '\r\n')
    local clean_sg_id=$(echo "$sg_id" | tr -d '\r\n')
    local clean_alb_arn=$(echo "$alb_arn" | tr -d '\r\n')
    local clean_tg_arn=$(echo "$tg_arn" | tr -d '\r\n')
    local clean_namespace_id=$(echo "$namespace_id" | head -n1 | tr -d '\r\n')
    
    cat > aws-resources.json << EOF
{
    "VpcId": "$clean_vpc_id",
    "InternetGatewayId": "$clean_igw_id",
    "PublicSubnet1Id": "$clean_public_subnet_1_id",
    "PublicSubnet2Id": "$clean_public_subnet_2_id",
    "PrivateSubnetId": "$clean_private_subnet_id",
    "NatGatewayId": "$clean_nat_gateway_id",
    "NatEipId": "$clean_nat_eip",
    "SecurityGroupId": "$clean_sg_id",
    "LoadBalancerArn": "$clean_alb_arn",
    "TargetGroupArn": "$clean_tg_arn",
    "NamespaceId": "$clean_namespace_id",
    "ClusterName": "$CLUSTER_NAME"
}
EOF
    
    if [ -f "service-discovery-arns.json" ]; then
        echo "  Merging Service Discovery ARNs into aws-resources.json..."
        jq '. * input' aws-resources.json service-discovery-arns.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
        rm -f service-discovery-arns.json
    fi
    
    print_success "Infrastructure resources saved to aws-resources.json"
    
    return 0
}

function deploy_ecs_services {
    print_header "DEPLOYING SERVICES TO ECS"
    
    if [ ! -f "aws-resources.json" ]; then
        print_error "aws-resources.json not found. Run infrastructure setup first."
        return 1
    fi
    
    local vpc_id=$(jq -r '.VpcId' aws-resources.json | tr -d '\r\n')
    local public_subnet_1_id=$(jq -r '.PublicSubnet1Id' aws-resources.json | tr -d '\r\n')
    local private_subnet_id=$(jq -r '.PrivateSubnetId' aws-resources.json | tr -d '\r\n')
    local sg_id=$(jq -r '.SecurityGroupId' aws-resources.json | tr -d '\r\n')
    local tg_arn=$(jq -r '.TargetGroupArn' aws-resources.json | tr -d '\r\n')
    
    
    if [ -z "$tg_arn" ] || [ "$tg_arn" = "null" ]; then
        print_error "Target Group ARN not found in aws-resources.json"
        return 1
    fi
    
    local backend_services=("movies-service" "cinema-catalog-service" "booking-service" "payment-service" "notification-service")
    
    for service in "${backend_services[@]}"; do
        local port="${SERVICES[$service]}"
        local repo_name="$REPO_PREFIX-$service"
        local image_uri="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$repo_name:latest"
        
        echo "Deploying $service..."
        
        cat > "task-definition-$service.json" << EOF
{
    "family": "$service",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "256",
    "memory": "512",
    "executionRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
    "taskRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "$service",
            "image": "$image_uri",
            "portMappings": [
                {
                    "containerPort": $port,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "healthCheck": {
                "command": [
                "CMD-SHELL",
                "wget --no-verbose --tries=1 --spider http://localhost:$port/ || exit 1"
                ],
                "interval": 30,
                "timeout": 10,
                "retries": 3,
                "startPeriod": 60
            },
            "environment": [
                {
                    "name": "MONGODB_ATLAS_URI",
                    "value": "mongodb+srv://quaolo_db_user:SP8c5btN0AEL9HcP@cluster-cinema.gctahhz.mongodb.net/sample_mflix?retryWrites=true&w=majority&appName=Cluster-cinema"
                },
                {
                    "name": "DB",
                    "value": "$(echo $service | tr '-' '_')"
                },
                {
                    "name": "PORT",
                    "value": "$port"
                }$(if [ "$service" = "movies-service" ]; then echo ',
                {
                    "name": "AWS_REGION",
                    "value": "'$REGION'"
                },
                {
                    "name": "MOVIE_IMAGES_BUCKET",
                    "value": "cinema-posters-'$AWS_ACCOUNT_ID'"
                }'; fi)
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/$service",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]
}
EOF
        
        aws ecs register-task-definition --cli-input-json "file://task-definition-$service.json" --region "$REGION" >/dev/null
        
        if [ $? -eq 0 ]; then
            print_success "Task definition registered for $service"
        else
            print_error "Task definition registration failed for $service"
            continue
        fi
        
        aws logs create-log-group --log-group-name "/ecs/$service" --region "$REGION" 2>/dev/null || true
        
        local service_status=$(aws ecs describe-services \
            --cluster "$CLUSTER_NAME" \
            --services "$service" \
            --region "$REGION" \
            --query 'services[0].status' \
            --output text 2>/dev/null || echo "NONE")

        if [ "$service_status" = "None" ] || [ "$service_status" = "null" ] || [ -z "$service_status" ]; then
            service_status="NONE"
        fi

        if [ "$service_status" = "ACTIVE" ]; then
            echo "  🔄 Service $service already exists and is ACTIVE, updating..."
            
                local sd_service_arn=$(jq -r ".ServiceDiscoveryARNs[\"$service\"]" aws-resources.json | tr -d '\r\n')
                
                if [ -n "$sd_service_arn" ] && [ "$sd_service_arn" != "null" ]; then
                    echo "    Using Service Discovery ARN: $sd_service_arn"
                    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service" \
                        --task-definition "$service" \
                        --network-configuration "awsvpcConfiguration={subnets=[$private_subnet_id],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
                        --service-registries "registryArn=$sd_service_arn" \
                        --region "$REGION" >/dev/null
                else
                    echo "    ERROR: Service Discovery ARN not found for $service, skipping Service Discovery"
                    aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service" \
                        --task-definition "$service" \
                        --network-configuration "awsvpcConfiguration={subnets=[$private_subnet_id],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
                        --region "$REGION" >/dev/null
            fi

            if [ $? -eq 0 ]; then
                print_success "Service $service updated successfully"
            else
                print_error "Service update failed for $service"
            fi

        else
            if [ "$service_status" != "NONE" ]; then
                echo "  WARNING: Service $service exists but is $service_status, deleting and recreating..."
                aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$service" --force --region "$REGION" >/dev/null 2>&1 || true
                
                local max_attempts=12
                local attempt=0
                while [ $attempt -lt $max_attempts ]; do
                    local current_status=$(aws ecs describe-services \
                        --cluster "$CLUSTER_NAME" \
                        --services "$service" \
                        --region "$REGION" \
                        --query 'services[0].status' \
                        --output text 2>/dev/null || echo "NONE")
                    
                    if [ "$current_status" = "NONE" ] || [ "$current_status" = "None" ] || [ -z "$current_status" ]; then
                        echo "  SUCCESS: Service $service deleted successfully"
                        break
                    fi
                    
                    echo "  WAIT: Waiting for service deletion... (attempt $((attempt + 1))/$max_attempts)"
                    sleep 5
                    attempt=$((attempt + 1))
                done
            fi

            echo "   Creating new service $service..."
            
                local sd_service_arn=$(jq -r ".ServiceDiscoveryARNs[\"$service\"]" aws-resources.json | tr -d '\r\n')
                
                if [ -n "$sd_service_arn" ] && [ "$sd_service_arn" != "null" ]; then
                    echo "    Using Service Discovery ARN: $sd_service_arn"
                    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$service" \
                        --task-definition "$service" --desired-count 1 --launch-type FARGATE \
                        --network-configuration "awsvpcConfiguration={subnets=[$private_subnet_id],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
                        --service-registries "registryArn=$sd_service_arn" \
                        --region "$REGION" >/dev/null
                else
                    echo "    ERROR: Service Discovery ARN not found for $service, skipping Service Discovery"
                    aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$service" \
                        --task-definition "$service" --desired-count 1 --launch-type FARGATE \
                        --network-configuration "awsvpcConfiguration={subnets=[$private_subnet_id],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
                        --region "$REGION" >/dev/null
            fi
        
        if [ $? -eq 0 ]; then
            print_success "Service $service deployed to ECS"
        else
            print_error "Service deployment failed for $service"
            fi
        fi
    done
    
    echo "Waiting for backend services..."
    sleep 60
    
    echo "Deploying API Gateway..."
    local service="api-gateway"
    local port="${SERVICES[$service]}"
        local repo_name="$REPO_PREFIX-$service"
        local image_uri="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$repo_name:latest"
    
    aws logs create-log-group --log-group-name "/ecs/$service" --region "$REGION" 2>/dev/null || true
    
    create_api_gateway_task_definition "$image_uri"
    
    aws ecs register-task-definition --cli-input-json "file://task-definition-$service.json" --region "$REGION" >/dev/null
    
    local service_status=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$service" --region "$REGION" --query 'services[0].status' --output text 2>/dev/null | tr -d '\r\n' || echo "NOT_FOUND")
    
    if [ "$service_status" = "ACTIVE" ]; then
        echo "   Service $service already exists and is ACTIVE, updating..."
        aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service" \
            --task-definition "$service" \
            --desired-count 1 \
            --network-configuration "awsvpcConfiguration={subnets=[$public_subnet_1_id],securityGroups=[$sg_id],assignPublicIp=ENABLED}" \
            --load-balancers "targetGroupArn=$tg_arn,containerName=api-gateway,containerPort=8080" \
            --region "$REGION" >/dev/null
    else
        echo "   Creating new service $service..."
        aws ecs create-service --cluster "$CLUSTER_NAME" --service-name "$service" \
            --task-definition "$service" --desired-count 1 --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$public_subnet_1_id],securityGroups=[$sg_id],assignPublicIp=ENABLED}" \
            --load-balancers "targetGroupArn=$tg_arn,containerName=api-gateway,containerPort=8080" \
            --enable-execute-command \
            --region "$REGION" >/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        print_success "API Gateway service deployed to ECS"
    else
        print_error "API Gateway service deployment failed"
    fi
    
    echo ""
    
    return 0
}

function show_status {
    print_header "DEPLOYMENT STATUS"
    
    if [ -f "aws-resources.json" ]; then
        local alb_arn=$(jq -r '.LoadBalancerArn // empty' aws-resources.json | tr -d '\r\n')
        if [ -n "$alb_arn" ] && [ "$alb_arn" != "null" ]; then
            local alb_dns=$(aws elbv2 describe-load-balancers --load-balancer-arns "$alb_arn" --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)
            echo "API Gateway URL: http://$alb_dns"
            echo "Available endpoints:"
            echo "  - http://$alb_dns/movies"
            echo "  - http://$alb_dns/cinemas" 
            echo "  - http://$alb_dns/bookings"
            echo "  - http://$alb_dns/payments"
            echo "  - http://$alb_dns/notifications"
        else
            echo "ALB not found"
        fi
        
        local codepipeline_role=$(jq -r '.CodePipelineRole // empty' aws-resources.json | tr -d '\r\n')
        local artifact_bucket=$(jq -r '.CodePipelineArtifactBucket // empty' aws-resources.json | tr -d '\r\n')
        
        if [ -n "$codepipeline_role" ] && [ "$codepipeline_role" != "null" ]; then
            echo ""
            echo "CI/CD Resources:"
            echo "  CodePipeline Role: $codepipeline_role"
            if [ -n "$artifact_bucket" ] && [ "$artifact_bucket" != "null" ]; then
                echo "  Artifact Bucket: $artifact_bucket"
            fi
            echo ""
        fi
    else
        echo "Resources file not found"
    fi
}

function cleanup_ecs_services {
    print_step "Cleaning ECS Services" "Removing existing services..."
    
    local services=$(aws ecs list-services --cluster "$CLUSTER_NAME" --region "$REGION" --query 'serviceArns' --output text 2>/dev/null || echo "")
    
    if [ -n "$services" ]; then
        echo "  Found existing services: $services"
        
        for service_arn in $services; do
            local service_name=$(echo "$service_arn" | cut -d'/' -f3)
            echo "  Deleting service: $service_name"
            
            aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$service_name" --force --region "$REGION" >/dev/null 2>&1 || true
        done
        
        echo "  Waiting for services to be deleted..."
        local max_attempts=30
        local attempt=0
        
        while [ $attempt -lt $max_attempts ]; do
            local remaining_services=$(aws ecs list-services --cluster "$CLUSTER_NAME" --region "$REGION" --query 'serviceArns' --output text 2>/dev/null || echo "")
            
            if [ -z "$remaining_services" ] || [ "$remaining_services" = "None" ]; then
                echo "  SUCCESS: All services deleted successfully"
                break
            fi
            
            echo "  WAIT: Waiting for services to be deleted... (attempt $((attempt + 1))/$max_attempts)"
            sleep 10
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -eq $max_attempts ]; then
            echo "  WARNING: Some services may still be in deletion process"
        fi
    else
        echo "  No existing services found"
    fi
}

function cleanup_duplicate_target_groups {
    print_step "Cleaning Duplicate Target Groups" "Removing old target groups..."
    
    local target_groups=$(aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[?TargetGroupName==`cinema-api-tg`].TargetGroupArn' --output text 2>/dev/null || echo "")
    
    if [ -n "$target_groups" ]; then
        for tg_arn in $target_groups; do
            aws elbv2 delete-target-group --target-group-arn "$tg_arn" --region "$REGION" >/dev/null 2>&1 || true
        done
        echo "  Target groups deleted"
    else
        echo "  No target groups found"
    fi
}

function cleanup_duplicate_load_balancers {
    print_step "Cleaning Duplicate Load Balancers" "Removing old load balancers..."
    
    local load_balancers=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[?LoadBalancerName==`cinema-alb`].LoadBalancerArn' --output text 2>/dev/null || echo "")
    
    if [ -n "$load_balancers" ]; then
        for alb_arn in $load_balancers; do
            aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$REGION" >/dev/null 2>&1 || true
        done
        echo "  Load balancers deleted"
        sleep 30
    else
        echo "  No load balancers found"
    fi
}

function cleanup_unused_elastic_ips {
    print_step "Cleaning Unused Elastic IPs" "Releasing all unused Elastic IPs..."
    
    local unused_eips=$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo "")
    
    if [ -n "$unused_eips" ] && [ "$unused_eips" != "None" ]; then
        local count=0
        for eip_id in $unused_eips; do
            if [ -n "$eip_id" ] && [ "$eip_id" != "None" ]; then
                if aws ec2 release-address --allocation-id "$eip_id" --region "$REGION" >/dev/null 2>&1; then
                    count=$((count + 1))
                fi
            fi
        done
        echo "  Released $count unused Elastic IPs"
    else
        echo "  No unused Elastic IPs found"
    fi
}

function cleanup_force_enis {
    print_step "Force Deleting ENIs" "Removing all network interfaces..."
    
    local enis=$(aws ec2 describe-network-interfaces --region "$REGION" --query 'NetworkInterfaces[?Status==`in-use`].NetworkInterfaceId' --output text 2>/dev/null || echo "")
    
    if [ -n "$enis" ] && [ "$enis" != "None" ]; then
        echo "  Found in-use ENIs: $enis"
        for eni in $enis; do
            echo "  Deleting ENI: $eni"
            local attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "")
            if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                echo "    Detaching from instance..."
                aws ec2 detach-network-interface --attachment-id "$attachment_id" --force --region "$REGION" 2>/dev/null || true
                sleep 5
            fi
            aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || echo "    Failed to delete: $eni"
        done
        echo "  SUCCESS: ENIs cleanup completed"
    else
        echo "  No in-use ENIs found"
    fi
}

function cleanup_ecr_repositories {
    print_step "Cleaning ECR Repositories" "Removing container images..."
    
    local repos=$(aws ecr describe-repositories --region "$REGION" --query 'repositories[?contains(repositoryName, `cinema-`)].repositoryName' --output text 2>/dev/null || echo "")
    
    if [ -n "$repos" ] && [ "$repos" != "None" ]; then
        for repo in $repos; do
            aws ecr delete-repository --repository-name "$repo" --force --region "$REGION" >/dev/null 2>&1
        done
        echo "  ECR repositories deleted"
    else
        echo "  No ECR repositories found"
    fi
}

function cleanup_cloudwatch_logs {
    print_step "Cleaning CloudWatch Log Groups" "Removing log groups to save costs..."
    
    local log_groups=$(aws logs describe-log-groups --log-group-name-prefix "/ecs/" --region "$REGION" --query 'logGroups[].logGroupName' --output text 2>/dev/null || echo "")
    
    if [ -n "$log_groups" ] && [ "$log_groups" != "None" ]; then
        for log_group in $log_groups; do
            aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" >/dev/null 2>&1
        done
        echo "  CloudWatch log groups deleted"
    else
        echo "  No CloudWatch log groups found"
    fi
}

function cleanup_service_discovery {
    print_step "Cleaning Service Discovery" "Removing services and namespaces..."
    
    local discovery_services=("movies-service" "cinema-catalog-service" "booking-service" "payment-service" "notification-service")
    
    for service in "${discovery_services[@]}"; do
        local services=$(aws servicediscovery list-services --region "$REGION" --query "Services[?Name=='$service'].Id" --output text 2>/dev/null || echo "")
        
        if [ -n "$services" ] && [ "$services" != "None" ]; then
            for service_id in $services; do
                aws servicediscovery delete-service --id "$service_id" --region "$REGION" >/dev/null 2>&1
            done
        fi
    done
    
    local namespaces=$(aws servicediscovery list-namespaces --region "$REGION" --query 'Namespaces[?Name==`cinema-cluster.local`].Id' --output text 2>/dev/null || echo "")
    
    if [ -n "$namespaces" ] && [ "$namespaces" != "None" ]; then
        for namespace in $namespaces; do
            aws servicediscovery delete-namespace --id "$namespace" --region "$REGION" >/dev/null 2>&1
        done
        echo "  Service Discovery cleaned up"
    else
        echo "  No Service Discovery resources found"
    fi
}

function cleanup_ecs_cluster {
    print_step "Cleaning ECS Cluster" "Removing cluster..."
    
    local cluster_status=$(aws ecs describe-clusters --clusters cinema-cluster --region "$REGION" --query 'clusters[0].status' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$cluster_status" != "NOT_FOUND" ] && [ "$cluster_status" != "None" ]; then
        aws ecs delete-cluster --cluster cinema-cluster --region "$REGION" >/dev/null 2>&1
        echo "  ECS cluster deleted"
    else
        echo "  No ECS cluster found"
    fi
}

function cleanup_existing_cinema_vpcs {
    print_step "Cleaning Existing Cinema VPCs" "Removing old VPCs..."
    
    local cinema_vpcs=$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[?Tags[?Key==`Name` && Value==`cinema-vpc`]].VpcId' --output text)
    
    if [ -n "$cinema_vpcs" ]; then
        for vpc in $cinema_vpcs; do
            echo "  Cleaning up VPC: $vpc"
            
            local endpoint_ids=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" --region "$REGION" --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || echo "")
            if [ -n "$endpoint_ids" ] && [ "$endpoint_ids" != "None" ]; then
                echo "    Deleting VPC endpoints..."
                for endpoint_id in $endpoint_ids; do
                    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint_id" --region "$REGION" >/dev/null 2>&1
                done
                sleep 30
            fi
            
            local max_eni_retries=5
            local eni_retry_count=0
            while [ $eni_retry_count -lt $max_eni_retries ]; do
                local enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$REGION" 2>/dev/null || echo "")
                if [ -n "$enis" ] && [ "$enis" != "None" ]; then
                    echo "    Deleting network interfaces (attempt $((eni_retry_count + 1))/$max_eni_retries)..."
                    local failed_enis=""
                    for eni in $enis; do
                        echo "      Deleting ENI: $eni"
                        local attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text --region "$REGION" 2>/dev/null || echo "")
                        if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                            echo "        Detaching ENI $eni (attachment: $attachment_id)"
                            aws ec2 detach-network-interface --attachment-id "$attachment_id" --force --region "$REGION" >/dev/null 2>&1
                            sleep 10
                        fi
                        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" >/dev/null 2>&1
                        if [ $? -ne 0 ]; then
                            failed_enis="$failed_enis $eni"
                        fi
                    done
                    if [ -n "$failed_enis" ]; then
                        echo "    Some ENIs still in use, waiting 30 seconds..."
                        sleep 30
                        eni_retry_count=$((eni_retry_count + 1))
                    else
                        break
                    fi
                else
                    break
                fi
            done
            
            local remaining_enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$remaining_enis" ] && [ "$remaining_enis" != "None" ]; then
                echo "    WARNING: Some ENIs still exist, but proceeding with subnet deletion..."
                echo "    Remaining ENIs: $remaining_enis"
            else
                echo "    All ENIs successfully deleted"
            fi
            
            local subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$subnets" ]; then
                echo "    Deleting subnets..."
                local max_subnet_retries=3
                local subnet_retry_count=0
                while [ $subnet_retry_count -lt $max_subnet_retries ]; do
                    local failed_subnets=""
                    for subnet in $subnets; do
                        echo "      Deleting subnet: $subnet"
                        aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" >/dev/null 2>&1
                        if [ $? -ne 0 ]; then
                            failed_subnets="$failed_subnets $subnet"
                        fi
                    done
                    if [ -n "$failed_subnets" ]; then
                        echo "    Some subnets still have dependencies, waiting 30 seconds..."
                        sleep 30
                        subnet_retry_count=$((subnet_retry_count + 1))
                        subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
                    else
                        break
                    fi
                done
                sleep 30
            fi
            
            local route_tables=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$route_tables" ]; then
                echo "    Deleting custom route tables..."
                for rt in $route_tables; do
                    echo "      Deleting route table: $rt"
                    aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" >/dev/null 2>&1
                done
                sleep 10
            fi
            
            local security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$security_groups" ]; then
                echo "    Deleting security groups..."
                for sg in $security_groups; do
                    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1
                done
            fi
            
            local nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State==`available`].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$nat_gateways" ]; then
                echo "    Deleting NAT gateways..."
                for nat in $nat_gateways; do
                    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" >/dev/null 2>&1
                done
                sleep 60
            fi
            
            local igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
            if [ -n "$igw" ] && [ "$igw" != "None" ]; then
                echo "    Deleting internet gateway..."
                aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" >/dev/null 2>&1
                aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" >/dev/null 2>&1
            fi
            
            echo "    Verifying all resources are deleted..."
            local remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
            local remaining_rt=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region "$REGION" 2>/dev/null || echo "")
            local remaining_sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
            local remaining_nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State==`available`].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
            local remaining_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
            
            if [ -n "$remaining_rt" ] && [ "$remaining_rt" != "None" ]; then
                echo "    WARNING: Route tables still exist: $remaining_rt"
                echo "    Attempting to force delete remaining route tables..."
                for rt in $remaining_rt; do
                    aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" >/dev/null 2>&1
                done
                sleep 10
            fi
            if [ -n "$remaining_subnets" ] && [ "$remaining_subnets" != "None" ]; then
                echo "    WARNING: Subnets still exist: $remaining_subnets"
                echo "    Attempting to force delete remaining subnets..."
                for subnet in $remaining_subnets; do
                    aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" >/dev/null 2>&1
                done
                sleep 10
            fi
            if [ -n "$remaining_sgs" ] && [ "$remaining_sgs" != "None" ]; then
                echo "    WARNING: Security groups still exist: $remaining_sgs"
                echo "    Attempting to force delete remaining security groups..."
                for sg in $remaining_sgs; do
                    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1
                done
                sleep 10
            fi
            if [ -n "$remaining_nats" ] && [ "$remaining_nats" != "None" ]; then
                echo "    WARNING: NAT gateways still exist: $remaining_nats"
                echo "    Attempting to force delete remaining NAT gateways..."
                for nat in $remaining_nats; do
                    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" >/dev/null 2>&1
                done
                sleep 30
            fi
            if [ -n "$remaining_igw" ] && [ "$remaining_igw" != "None" ]; then
                echo "    WARNING: Internet gateway still exists: $remaining_igw"
                echo "    Attempting to force delete remaining internet gateway..."
                aws ec2 detach-internet-gateway --internet-gateway-id "$remaining_igw" --vpc-id "$vpc" --region "$REGION" >/dev/null 2>&1
                aws ec2 delete-internet-gateway --internet-gateway-id "$remaining_igw" --region "$REGION" >/dev/null 2>&1
                sleep 10
            fi
            
            echo "    Deleting VPC..."
            local vpc_delete_output=$(aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>&1)
            if [ $? -eq 0 ]; then
                echo "    Verifying VPC deletion..."
                sleep 5
                local vpc_exists=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --region "$REGION" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
                if [ -n "$vpc_exists" ] && [ "$vpc_exists" != "None" ]; then
                    
                    echo "  Checking for remaining resources..."
                    local final_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
                    local final_sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
                    local final_nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State==`available`].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
                    local final_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
                    local final_rt=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region "$REGION" 2>/dev/null || echo "")
                    
                    if [ -n "$final_subnets" ] && [ "$final_subnets" != "None" ]; then
                        echo "  Remaining subnets: $final_subnets"
                    fi
                    if [ -n "$final_sgs" ] && [ "$final_sgs" != "None" ]; then
                        echo "  Remaining security groups: $final_sgs"
                    fi
                    if [ -n "$final_nats" ] && [ "$final_nats" != "None" ]; then
                        echo "  Remaining NAT gateways: $final_nats"
                    fi
                    if [ -n "$final_igw" ] && [ "$final_igw" != "None" ]; then
                        echo "  Remaining internet gateway: $final_igw"
                    fi
                    if [ -n "$final_rt" ] && [ "$final_rt" != "None" ]; then
                        echo "  Remaining route tables: $final_rt"
                    fi
                    
                    echo "  VPC $vpc requires manual cleanup"
                else
                    echo "  VPC $vpc deleted successfully"
                fi
            else
                echo "  Checking for remaining resources..."
                local final_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
                local final_sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
                local final_nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" --query 'NatGateways[?State==`available`].NatGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
                local final_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "")
                
                if [ -n "$final_subnets" ] && [ "$final_subnets" != "None" ]; then
                    echo "  Remaining subnets: $final_subnets"
                fi
                if [ -n "$final_sgs" ] && [ "$final_sgs" != "None" ]; then
                    echo "  Remaining security groups: $final_sgs"
                fi
                if [ -n "$final_nats" ] && [ "$final_nats" != "None" ]; then
                    echo "  Remaining NAT gateways: $final_nats"
                fi
                if [ -n "$final_igw" ] && [ "$final_igw" != "None" ]; then
                    echo "  Remaining internet gateway: $final_igw"
                fi
            fi
        done
        
        echo "  VPCs cleaned up"
    else
        echo "  No VPCs found"
    fi
}

function cleanup_cloudwatch_logs {
    print_step "Cleaning CloudWatch Log Groups" "Removing log groups to save costs..."
    
    local log_groups=(
        "/ecs/api-gateway"
        "/ecs/booking-service" 
        "/ecs/cinema-catalog-service"
        "/ecs/movies-service"
        "/ecs/notification-service"
        "/ecs/payment-service"
    )
    
    for log_group in "${log_groups[@]}"; do
        if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "$REGION" --query 'logGroups[].logGroupName' --output text 2>/dev/null | grep -q "$log_group"; then
            echo "  DELETE:  Deleting log group: $log_group"
            aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" >/dev/null 2>&1 || true
        else
            echo "   Log group $log_group not found (already clean)"
        fi
    done
    
    print_success "CloudWatch Log Groups cleaned up"
}

function cleanup_s3_resources {
    print_step "Cleaning up S3 Resources" "Removing S3 bucket and objects..."
    
    if [ -f "aws-resources.json" ]; then
        local bucket_name=$(jq -r '.S3Bucket // empty' aws-resources.json)
        if [ -n "$bucket_name" ] && [ "$bucket_name" != "null" ]; then
            aws s3 rb "s3://$bucket_name" --region "$REGION" --force >/dev/null 2>&1 || true
            
            print_success "S3 bucket $bucket_name cleaned up"
        else
            print_success "No S3 bucket found in aws-resources.json"
        fi
    else
        local bucket_name="cinema-posters-$AWS_ACCOUNT_ID"
        if aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null; then
            aws s3 rb "s3://$bucket_name" --region "$REGION" --force >/dev/null 2>&1 || true
            
            print_success "S3 bucket $bucket_name cleaned up"
        else
            print_success "No S3 bucket found to clean up"
        fi
    fi
}

function create_s3_bucket {
    print_step "Creating S3 Bucket" "Setting up bucket for movie posters..."

    local bucket_name="cinema-posters-$AWS_ACCOUNT_ID"
    
    if aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null; then
        print_success "Bucket $bucket_name already exists, skipping creation"
        
        aws s3api put-public-access-block \
            --bucket "$bucket_name" \
            --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
            --region "$REGION" >/dev/null 2>&1 || true

        print_success "Block Public Access disabled for existing bucket $bucket_name"
        
        if [ -f "aws-resources.json" ]; then
            local existing_bucket=$(jq -r '.S3Bucket // empty' aws-resources.json)
            if [ -z "$existing_bucket" ] || [ "$existing_bucket" = "null" ]; then
                jq --arg bucket "$bucket_name" '.S3Bucket = $bucket' aws-resources.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
                print_success "Bucket added to aws-resources.json"
                fi
            else
            echo "{\"S3Bucket\": \"$bucket_name\"}" > aws-resources.json
            print_success "aws-resources.json created with S3 bucket"
        fi
    else
        aws s3api create-bucket \
            --bucket "$bucket_name" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" >/dev/null

        print_success "S3 bucket created: $bucket_name"

        aws s3api put-public-access-block \
            --bucket "$bucket_name" \
            --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
            --region "$REGION" >/dev/null

        print_success "Block Public Access disabled for $bucket_name"

        cat > bucket-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$bucket_name/*"
    }
  ]
}
EOF

        aws s3api put-bucket-policy --bucket "$bucket_name" --policy file://bucket-policy.json --region "$REGION"
        rm -f bucket-policy.json
        print_success "Public read policy applied to $bucket_name"
    fi

    if [ -f "aws-resources.json" ]; then
        jq --arg bucket "$bucket_name" '.S3Bucket = $bucket' aws-resources.json > aws-resources.tmp && mv aws-resources.tmp aws-resources.json
    else
        echo "{\"S3Bucket\": \"$bucket_name\"}" > aws-resources.json
        print_success "aws-resources.json created with S3 bucket"
    fi
}

function upload_s3_posters {
    print_step "Uploading Demo Posters" "Adding initial objects to S3..."

    if [ ! -f "aws-resources.json" ]; then
        print_error "aws-resources.json not found. Cannot determine S3 bucket name."
        return 1
    fi

    local bucket_name=$(jq -r '.S3Bucket' aws-resources.json)
    
    if [ -z "$bucket_name" ] || [ "$bucket_name" = "null" ]; then
        print_error "S3Bucket not found in aws-resources.json"
        return 1
    fi

    if [ ! -d "s3/posters" ]; then
        print_error "Local s3/posters directory not found. Please create it with demo files."
        return 1
    fi

    local file_count=$(find s3/posters -name "*.txt" | wc -l)
    if [ "$file_count" -eq 0 ]; then
        print_error "No .txt files found in s3/posters directory"
        return 1
    fi

    aws s3 cp s3/posters/ "s3://$bucket_name/movies/" --recursive --region "$REGION"

    print_success "Demo posters uploaded to S3 bucket: $bucket_name/movies/ ($file_count files)"
}

function create_ecs_role {
    print_step "Creating ECS Task Execution Role" "Setting up IAM role for ECS tasks..."
    
    if aws iam get-role --role-name ecsTaskExecutionRole --region "$REGION" >/dev/null 2>&1; then
        print_success "ECS Task Execution Role already exists"
        
        if aws iam list-attached-role-policies --role-name ecsTaskExecutionRole --region "$REGION" --query 'AttachedPolicies[?PolicyArn==`arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess`]' --output text | grep -q "AmazonS3ReadOnlyAccess"; then
            print_success "S3 permissions already attached"
        else
            aws iam attach-role-policy \
                --role-name ecsTaskExecutionRole \
                --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
                --region "$REGION" >/dev/null
            print_success "S3 permissions added to existing role"
        fi
        return 0
    fi
    
    aws iam create-role \
        --role-name ecsTaskExecutionRole \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }' \
        --region "$REGION" >/dev/null
    
    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
        --region "$REGION" >/dev/null
    
    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
        --region "$REGION" >/dev/null
    
    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
        --region "$REGION" >/dev/null
    
    print_success "ECS Task Execution Role created with required policies"
}

function create_vpc_endpoints {
    print_step "Creating VPC Endpoints" "Setting up VPC endpoints for ECS services..."
    
    local vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=cinema-vpc" --region "$REGION" --query "Vpcs[0].VpcId" --output text)
    local subnet_ids=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query "Subnets[].SubnetId" --output text)
    
    local sg_id=$(aws ec2 create-security-group --group-name cinema-vpc-endpoints-sg --description "SG for VPC Endpoints" --vpc-id "$vpc_id" --region "$REGION" --query 'GroupId' --output text)
    
    aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol -1 --cidr 10.0.0.0/16 --region "$REGION" >/dev/null
    
    echo "  Creating ECR API endpoint..."
    if aws ec2 create-vpc-endpoint \
      --vpc-id "$vpc_id" \
      --vpc-endpoint-type Interface \
      --service-name com.amazonaws.$REGION.ecr.api \
      --subnet-ids $subnet_ids \
      --security-group-ids "$sg_id" \
      --no-private-dns-enabled \
      --region "$REGION" >/dev/null 2>&1; then
        echo "  SUCCESS: ECR API endpoint created"
    else
        echo "  WARNING:  ECR API endpoint creation failed (may already exist)"
    fi
    
    echo "  Creating ECR DKR endpoint..."
    if aws ec2 create-vpc-endpoint \
      --vpc-id "$vpc_id" \
      --vpc-endpoint-type Interface \
      --service-name com.amazonaws.$REGION.ecr.dkr \
      --subnet-ids $subnet_ids \
      --security-group-ids "$sg_id" \
      --no-private-dns-enabled \
      --region "$REGION" >/dev/null 2>&1; then
        echo "  SUCCESS: ECR DKR endpoint created"
    else
        echo "  WARNING:  ECR DKR endpoint creation failed (may already exist)"
    fi
    
    echo "  Creating S3 Gateway endpoint..."
    local route_table_id=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query "RouteTables[0].RouteTableId" --output text)
    
    if aws ec2 create-vpc-endpoint \
      --vpc-id "$vpc_id" \
      --service-name com.amazonaws.$REGION.s3 \
      --route-table-ids "$route_table_id" \
      --region "$REGION" >/dev/null 2>&1; then
        echo "  SUCCESS: S3 Gateway endpoint created"
    else
        echo "  WARNING:  S3 Gateway endpoint creation failed (may already exist)"
    fi
    
    print_success "VPC Endpoints creation completed!"
}

function delete_vpc_endpoints {
    print_step "Deleting VPC Endpoints" "Removing VPC endpoints..."
    
    local vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=cinema-vpc" --region "$REGION" --query "Vpcs[0].VpcId" --output text)
    
    local endpoint_ids=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query "VpcEndpoints[].VpcEndpointId" --output text)
    
    for id in $endpoint_ids; do
        if [ -n "$id" ] && [ "$id" != "None" ]; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$id" --region "$REGION" >/dev/null 2>&1 || true
        fi
    done
    
    local sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=cinema-vpc-endpoints-sg" --region "$REGION" --query "SecurityGroups[0].GroupId" --output text)
    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        aws ec2 delete-security-group --group-id "$sg_id" --region "$REGION" >/dev/null 2>&1 || true
    fi
    
    print_success "VPC Endpoints deleted successfully!"
}

function cleanup_vpc_robust {
    local vpc_id="$1"
    
    print_step "Robust VPC Cleanup" "Removing all VPC dependencies..."
    
    sleep 10
    
    delete_vpc_endpoints
    
    print_step "Deleting Network Interfaces" "Removing ENIs..."
    aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null | while read eni; do
        if [ -n "$eni" ] && [ "$eni" != "None" ]; then
            echo "  Deleting ENI: $eni"
            aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" >/dev/null 2>&1 || true
        fi
    done
    
    sleep 10
    
    print_step "Deleting Route Tables" "Removing custom route tables..."
    aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null | while read rtb; do
        if [ -n "$rtb" ] && [ "$rtb" != "None" ]; then
            echo "  Deleting route table: $rtb"
            aws ec2 delete-route-table --route-table-id "$rtb" --region "$REGION" >/dev/null 2>&1 || true
        fi
    done
    
    print_step "Deleting NAT Gateway" "Removing NAT Gateway and Elastic IP..."
    if [ -f "aws-resources.json" ]; then
        local nat_gateway_id=$(jq -r '.NatGatewayId // empty' aws-resources.json | tr -d '\r\n')
        local nat_eip_id=$(jq -r '.NatEipId // empty' aws-resources.json | tr -d '\r\n')
        
        if [ -n "$nat_gateway_id" ] && [ "$nat_gateway_id" != "null" ]; then
            echo "  Deleting NAT Gateway: $nat_gateway_id"
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat_gateway_id" --region "$REGION" >/dev/null 2>&1 || true
        fi
        
        if [ -n "$nat_eip_id" ] && [ "$nat_eip_id" != "null" ]; then
            echo "  Releasing Elastic IP: $nat_eip_id"
            aws ec2 release-address --allocation-id "$nat_eip_id" --region "$REGION" >/dev/null 2>&1 || true
        fi
        
        local alb_arn=$(jq -r '.LoadBalancerArn // empty' aws-resources.json | tr -d '\r\n')
        local tg_arn=$(jq -r '.TargetGroupArn // empty' aws-resources.json | tr -d '\r\n')
        
        if [ -n "$alb_arn" ] && [ "$alb_arn" != "null" ]; then
            echo "  Deleting Load Balancer: $alb_arn"
            aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$REGION" >/dev/null 2>&1 || true
        fi
        
        if [ -n "$tg_arn" ] && [ "$tg_arn" != "null" ]; then
            echo "  Deleting Target Group: $tg_arn"
            aws elbv2 delete-target-group --target-group-arn "$tg_arn" --region "$REGION" >/dev/null 2>&1 || true
        fi
        
        local namespace_id=$(jq -r '.NamespaceId // empty' aws-resources.json | tr -d '\r\n')
        if [ -n "$namespace_id" ] && [ "$namespace_id" != "null" ]; then
            echo "  Deleting Service Discovery namespace: $namespace_id"
            aws servicediscovery delete-namespace --id "$namespace_id" --region "$REGION" >/dev/null 2>&1 || true
        fi
    fi
    
    print_step "Cleaning Unused Elastic IPs" "Releasing all unused Elastic IPs..."
    local unused_eips=$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo "")
    
    if [ -n "$unused_eips" ] && [ "$unused_eips" != "None" ]; then
        echo "  Found unused Elastic IPs: $unused_eips"
        local count=0
        for eip_id in $unused_eips; do
            if [ -n "$eip_id" ] && [ "$eip_id" != "None" ]; then
                echo "  Releasing unused Elastic IP: $eip_id"
                if aws ec2 release-address --allocation-id "$eip_id" --region "$REGION" >/dev/null 2>&1; then
                    count=$((count + 1))
                fi
            fi
        done
        echo "  SUCCESS: Released $count unused Elastic IPs"
    else
        echo "  No unused Elastic IPs found"
    fi
    
    print_step "Deleting Subnets" "Removing subnets..."
    aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null | while read subnet; do
        if [ -n "$subnet" ] && [ "$subnet" != "None" ]; then
            echo "  Deleting subnet: $subnet"
            aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" >/dev/null 2>&1 || true
        fi
    done
    
    print_step "Deleting Internet Gateway" "Removing IGW..."
    local igw_id=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --region "$REGION" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
    if [ -n "$igw_id" ] && [ "$igw_id" != "None" ]; then
        echo "  Detaching IGW: $igw_id"
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" --region "$REGION" >/dev/null 2>&1 || true
        echo "  Deleting IGW: $igw_id"
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" --region "$REGION" >/dev/null 2>&1 || true
    fi
    
    print_step "Deleting Security Groups" "Removing custom security groups..."
    aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | while read sg; do
        if [ -n "$sg" ] && [ "$sg" != "None" ]; then
            echo "  Deleting security group: $sg"
            aws ec2 delete-security-group --group-id "$sg" --region "$REGION" >/dev/null 2>&1 || true
        fi
    done
    
    sleep 10
    
    print_step "Deleting VPC" "Removing VPC..."
    aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION" >/dev/null 2>&1 || true
    
    print_success "VPC cleanup completed"
}

function cleanup_network_only {
    print_header "CLEANING UP NETWORK INFRASTRUCTURE ONLY"
    
    cleanup_alb_target_groups
    cleanup_elastic_ips
    cleanup_existing_cinema_vpcs
    
    print_success "Network infrastructure cleanup completed"
}

function cleanup_resources {
    print_header "CLEANING UP AWS RESOURCES"
    
    echo "Stopping ECS services..."
    for service in "${!SERVICES[@]}"; do
        aws ecs update-service --cluster "$CLUSTER_NAME" --service "$service" --desired-count 0 --region "$REGION" >/dev/null 2>&1 || true
        aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$service" --region "$REGION" >/dev/null 2>&1 || true
    done
    
    echo "Waiting for services to stop..."
    sleep 30
    
    echo "Stopping remaining tasks..."
    TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --region "$REGION" --query 'taskArns' --output text)
    if [ -n "$TASK_ARNS" ] && [ "$TASK_ARNS" != "None" ]; then
        for task_arn in $TASK_ARNS; do
            aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$task_arn" --region "$REGION" >/dev/null 2>&1 || true
        done
        sleep 30
    fi
    
    cleanup_ecs_cluster
    
    cleanup_cloudwatch_logs
    
    cleanup_s3_resources
    
    cleanup_ecr_repositories
    
    cleanup_service_discovery
    
    cleanup_duplicate_load_balancers
    
    cleanup_duplicate_target_groups
    
    cleanup_unused_elastic_ips
    
    cleanup_existing_cinema_vpcs
    
    echo "Waiting for cleanup to complete..."
    sleep 40
    
    # Non cancellare aws-resources.json se siamo in CodeBuild
    if [ "$CODEBUILD" != "true" ]; then
        rm -f aws-resources.json task-definition-*.json
    else
        rm -f task-definition-*.json
    fi
    
    print_success "All resources cleaned up successfully!"
}

# MAIN EXECUTION
print_header "CINEMA MICROSERVICES - AWS DEPLOYMENT"
echo "Region: $REGION"
echo "Account ID: $AWS_ACCOUNT_ID"
echo "Cluster: $CLUSTER_NAME"
echo ""

check_aws_cli

if [ "$CLEANUP" = "true" ]; then
    cleanup_resources
    exit 0
fi

success=true

if [ "$SKIP_ECR" != "true" ]; then
    if ! deploy_ecr; then
        print_error "ECR deployment failed!"
        exit 1
    fi
fi

if [ "$SKIP_ECS" != "true" ]; then
    if [ "$SKIP_INFRASTRUCTURE" != "true" ]; then
        if [ "$CLEANUP" = "true" ]; then
            print_step "Full Cleanup Mode" "Cleaning up all existing resources..."
            cleanup_unused_elastic_ips
            cleanup_duplicate_load_balancers
            cleanup_duplicate_target_groups
            cleanup_ecs_services
            cleanup_existing_cinema_vpcs
        else
            print_step "Smart Reuse Mode" "Reusing existing infrastructure where possible..."
            cleanup_ecs_services
        fi
        
        if ! deploy_ecs_infrastructure; then
            print_error "ECS infrastructure setup failed!"
            exit 1
        fi

        if ! create_s3_bucket; then
            print_error "S3 bucket creation failed!"
            exit 1
        fi

        if ! upload_s3_posters; then
            print_error "Failed to upload demo posters to S3"
            exit 1
        fi

        if [ "$CODEBUILD" != "true" ]; then
            create_codepipeline_role
            ensure_pipeline_bucket
            
            if [ "$CREATE_CODEPIPELINE" = "true" ]; then
                create_codepipeline
            fi
        fi
    else
        print_step "Skipping Infrastructure" "Using existing infrastructure..."
        echo "WARNING:  Skipping VPC, ALB, and infrastructure creation"
        echo "   Using existing resources from aws-resources.json"
        
        create_service_discovery_services
        
        if ! create_s3_bucket; then
            print_error "S3 bucket creation failed!"
            exit 1
        fi

        if ! upload_s3_posters; then
            print_error "Failed to upload demo posters to S3"
            exit 1
        fi
    fi
    
    if ! deploy_ecs_services; then
        print_error "ECS services deployment failed!"
        exit 1
    fi
fi

if [ "$success" = true ]; then
    show_status
    echo ""
    echo " DEPLOYMENT COMPLETED SUCCESSFULLY!"
else
    echo ""
    echo "ERROR: DEPLOYMENT FAILED!"
    exit 1
fi