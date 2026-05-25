#!/bin/bash
set -e

REGION="ap-southeast-1"
PROJECT="xbrain-w5"

# Tagging Strategy consistent with W6
TAGS="Key=Owner,Value=ngokhoangnam4268@gmail.com Key=Environment,Value=dev Key=CostCenter,Value=G5 Key=Application,Value=geekbrain Key=Project,Value=$PROJECT"
TAGS_ECS="key=Owner,value=ngokhoangnam4268@gmail.com key=Environment,value=dev key=CostCenter,value=G5 key=Application,value=geekbrain key=Project,value=$PROJECT"

# Các biến cần export từ trước
if [ -z "$VPC_ID" ] || [ -z "$PUB_SUBNET" ] || [ -z "$PRIV_SUBNET" ] || [ -z "$ALB_SG" ] || [ -z "$ECS_SG" ] || [ -z "$EFS_ID" ] || [ -z "$ACCOUNT_ID" ] || [ -z "$DDB_TABLE" ]; then
  echo "LỖI: Hãy export đầy đủ các biến mạng & lưu trữ!"
  exit 1
fi
if [ -z "$BEDROCK_KB_ID" ] || [ -z "$BEDROCK_DS_ID" ] || [ -z "$BEDROCK_MODEL_ID" ]; then
  echo "LỖI: Hãy làm phần Bedrock bằng tay và export BEDROCK_KB_ID, BEDROCK_DS_ID, BEDROCK_MODEL_ID!"
  exit 1
fi

echo "=== 1. LƯU PARAMETERS VÀO SSM ==="
aws ssm put-parameter --name "/geekbrain/BEDROCK_KB_ID" --value "$BEDROCK_KB_ID" --type String --overwrite --region $REGION > /dev/null
aws ssm put-parameter --name "/geekbrain/BEDROCK_DS_ID" --value "$BEDROCK_DS_ID" --type String --overwrite --region $REGION > /dev/null
aws ssm put-parameter --name "/geekbrain/BEDROCK_MODEL_ID" --value "$BEDROCK_MODEL_ID" --type String --overwrite --region $REGION > /dev/null
aws ssm put-parameter --name "/geekbrain/DYNAMODB_TABLE" --value "$DDB_TABLE" --type String --overwrite --region $REGION > /dev/null

echo "=== 2. ECR & BUILD IMAGE ==="
aws ecr create-repository --repository-name ${PROJECT}-backend --tags $TAGS --region $REGION > /dev/null || true
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/${PROJECT}-backend"

# Đăng nhập ECR & Push Image
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
echo "Đang build Docker Image..."
BACKEND_DIR="$(dirname "$(dirname "$(realpath "$0")")")/../../w5/backend"
cd "$BACKEND_DIR"
docker build -t ${PROJECT}-backend .
docker tag ${PROJECT}-backend:latest $ECR_URI:latest
docker push $ECR_URI:latest
cd -

echo "=== 3. IAM ROLES CHO ECS ==="
EXECUTION_ROLE_NAME="${PROJECT}-ecs-execution-role"
aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --tags $TAGS > /dev/null || true
aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy > /dev/null || true
aws iam put-role-policy --role-name $EXECUTION_ROLE_NAME --policy-name SSMReadPolicy --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameters\",\"ssm:GetParameter\"],\"Resource\":\"arn:aws:ssm:$REGION:$ACCOUNT_ID:parameter/geekbrain/*\"}]}" > /dev/null || true

TASK_ROLE_NAME="${PROJECT}-ecs-task-role"
aws iam create-role --role-name $TASK_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --tags $TAGS > /dev/null || true
aws iam put-role-policy --role-name $TASK_ROLE_NAME --policy-name AppPermissions --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:*\",\"dynamodb:*\",\"s3:*\",\"elasticfilesystem:*\"],\"Resource\":\"*\"}]}" > /dev/null || true
sleep 10 # Đợi role propagate

EXEC_ROLE_ARN=$(aws iam get-role --role-name $EXECUTION_ROLE_NAME --query 'Role.Arn' --output text)
TASK_ROLE_ARN=$(aws iam get-role --role-name $TASK_ROLE_NAME --query 'Role.Arn' --output text)

echo "=== 4. ALB (APPLICATION LOAD BALANCER) ==="
ALB_ARN=$(aws elbv2 create-load-balancer --name ${PROJECT}-alb --subnets $PUB_SUBNET subnet-098038f12b2f2f7b3 --security-groups $ALB_SG --tags $TAGS --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
TG_ARN=$(aws elbv2 create-target-group --name ${PROJECT}-tg --protocol HTTP --port 8001 --vpc-id $VPC_ID --target-type ip --health-check-path /health --tags $TAGS --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN --region $REGION > /dev/null

echo "=== 5. ECS CLUSTER & TASK DEFINITION ==="
aws ecs create-cluster --cluster-name $PROJECT --tags $TAGS_ECS --region $REGION > /dev/null || true

cat <<EOF > task-def.json
{
  "family": "${PROJECT}-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "volumes": [
    {
      "name": "efs-knowledge-base",
      "efsVolumeConfiguration": { "fileSystemId": "$EFS_ID", "rootDirectory": "/", "transitEncryption": "ENABLED" }
    },
    {
      "name": "efs-database",
      "efsVolumeConfiguration": { "fileSystemId": "$EFS_ID", "rootDirectory": "/", "transitEncryption": "ENABLED" }
    }
  ],
  "containerDefinitions": [
    {
      "name": "${PROJECT}-backend",
      "image": "$ECR_URI:latest",
      "portMappings": [{ "containerPort": 8001, "protocol": "tcp" }, { "containerPort": 8000, "protocol": "tcp" }],
      "mountPoints": [
        { "sourceVolume": "efs-knowledge-base", "containerPath": "/mnt/efs", "readOnly": false },
        { "sourceVolume": "efs-database", "containerPath": "/mnt/efs/database", "readOnly": false }
      ],
      "environment": [
        { "name": "AWS_DEFAULT_REGION", "value": "$REGION" },
        { "name": "DYNAMODB_REGION", "value": "$REGION" },
        { "name": "EFS_KNOWLEDGE_BASE_PATH", "value": "/mnt/efs/knowledge_base" },
        { "name": "DB_PATH", "value": "/mnt/efs/database/geekbrain.db" }
      ],
      "secrets": [
        { "name": "BEDROCK_KB_ID", "valueFrom": "arn:aws:ssm:$REGION:$ACCOUNT_ID:parameter/geekbrain/BEDROCK_KB_ID" },
        { "name": "DYNAMODB_TABLE", "valueFrom": "arn:aws:ssm:$REGION:$ACCOUNT_ID:parameter/geekbrain/DYNAMODB_TABLE" }
      ],
      "essential": true
    }
  ]
}
EOF

aws ecs register-task-definition --cli-input-json file://task-def.json --tags $TAGS_ECS --region $REGION > /dev/null

echo "=== 6. ECS SERVICE ==="
aws ecs create-service \
    --cluster $PROJECT \
    --service-name ${PROJECT}-backend-svc \
    --task-definition ${PROJECT}-backend \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$PRIV_SUBNET],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=${PROJECT}-backend,containerPort=8001" \
    --tags $TAGS_ECS \
    --region $REGION > /dev/null

echo "Đã triển khai xong Backend! URL Load Balancer: http://$ALB_DNS"
echo "Bạn có thể test API sau vài phút: curl http://$ALB_DNS/health"
