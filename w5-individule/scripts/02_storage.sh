#!/bin/bash
set -e

REGION="ap-southeast-1"
PROJECT="xbrain-w5"
AZ="${REGION}a"

# Tagging Strategy consistent with W6
TAGS="Key=Owner,Value=ngokhoangnam4268@gmail.com Key=Environment,Value=dev Key=CostCenter,Value=G5 Key=Application,Value=geekbrain Key=Project,Value=$PROJECT"
TAGS_COMMA="Owner=ngokhoangnam4268@gmail.com,Environment=dev,CostCenter=G5,Application=geekbrain,Project=$PROJECT"

# Các biến export từ 01_network.sh (cần load vào trước khi chạy)
if [ -z "$PRIV_SUBNET" ] || [ -z "$ECS_SG" ] || [ -z "$EFS_SG" ] || [ -z "$ACCOUNT_ID" ]; then
  echo "LỖI: Hãy export PRIV_SUBNET, ECS_SG, EFS_SG, ACCOUNT_ID từ 01_network.sh trước!"
  exit 1
fi

echo "=== 1. TẠO DYNAMODB TABLE ==="
DDB_TABLE="${PROJECT}-conversations"
aws dynamodb create-table \
    --table-name $DDB_TABLE \
    --attribute-definitions AttributeName=session_id,AttributeType=S \
    --key-schema AttributeName=session_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags $TAGS \
    --region $REGION > /dev/null || true
echo "DynamoDB table: $DDB_TABLE"

echo "=== 2. TẠO S3 KNOWLEDGE BASE BUCKET ==="
KB_BUCKET="${PROJECT}-kb-sg-${ACCOUNT_ID}"
aws s3api create-bucket --bucket $KB_BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION > /dev/null || true
aws s3api put-bucket-tagging --bucket $KB_BUCKET --tagging "TagSet=[{Key=Owner,Value=ngokhoangnam4268@gmail.com},{Key=Environment,Value=dev},{Key=CostCenter,Value=G5},{Key=Application,Value=geekbrain},{Key=Project,Value=$PROJECT}]" --region $REGION > /dev/null || true
echo "S3 Bucket: $KB_BUCKET"

echo "=== 3. MH3: TẠO EFS (ONE ZONE) & MOUNT TARGET ==="
EFS_ID=$(aws efs create-file-system \
    --availability-zone-name $AZ \
    --backup \
    --encrypted \
    --tags Key=Name,Value=${PROJECT}-efs $TAGS \
    --query 'FileSystemId' --output text --region $REGION)
echo "Đang đợi EFS available..."
sleep 10
aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $PRIV_SUBNET \
    --security-groups $EFS_SG \
    --region $REGION > /dev/null
echo "EFS FileSystemId: $EFS_ID"

echo "=== 4. MH3: AWS BACKUP PLAN ==="
VAULT_NAME="${PROJECT}-vault"
aws backup create-backup-vault --backup-vault-name $VAULT_NAME --backup-vault-tags $TAGS_COMMA --region $REGION > /dev/null || true

PLAN_ID=$(aws backup create-backup-plan \
    --backup-plan "{
        \"BackupPlanName\": \"${PROJECT}-daily-plan\",
        \"Rules\": [{
            \"RuleName\": \"DailyBackup\",
            \"TargetBackupVaultName\": \"$VAULT_NAME\",
            \"ScheduleExpression\": \"cron(0 17 * * ? *)\",
            \"Lifecycle\": { \"DeleteAfterDays\": 7 }
        }]
    }" \
    --backup-plan-tags $TAGS_COMMA \
    --query 'BackupPlanId' --output text --region $REGION)

# IAM Role cho AWS Backup
BACKUP_ROLE_NAME="${PROJECT}-backup-role"
aws iam create-role --role-name $BACKUP_ROLE_NAME \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"backup.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null || true
aws iam attach-role-policy --role-name $BACKUP_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup > /dev/null || true
sleep 10 # Đợi role propagate

BACKUP_ROLE_ARN=$(aws iam get-role --role-name $BACKUP_ROLE_NAME --query 'Role.Arn' --output text)
aws backup create-backup-selection \
    --backup-plan-id $PLAN_ID \
    --backup-selection "{
        \"SelectionName\": \"${PROJECT}-selection\",
        \"IamRoleArn\": \"$BACKUP_ROLE_ARN\",
        \"Resources\": [
            \"arn:aws:elasticfilesystem:$REGION:$ACCOUNT_ID:file-system/$EFS_ID\",
            \"arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/$DDB_TABLE\"
        ]
    }" \
    --region $REGION > /dev/null

echo "Đã cấu hình AWS Backup Plan $PLAN_ID lưu retention 7 ngày!"

echo "---"
echo "LƯU LẠI CÁC GIÁ TRỊ NÀY CHO CÁC SCRIPT SAU:"
echo "export DDB_TABLE=$DDB_TABLE"
echo "export KB_BUCKET=$KB_BUCKET"
echo "export EFS_ID=$EFS_ID"
echo "export EFS_SG=$EFS_SG"
echo "---"
