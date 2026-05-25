#!/bin/bash
set -e

REGION="ap-southeast-1"
PROJECT="xbrain-w5"

# Tagging Strategy consistent with W6
TAGS="Key=Owner,Value=ngokhoangnam4268@gmail.com Key=Environment,Value=dev Key=CostCenter,Value=G5 Key=Application,Value=geekbrain Key=Project,Value=$PROJECT"
TAGS_JSON='{"Owner":"ngokhoangnam4268@gmail.com","Environment":"dev","CostCenter":"G5","Application":"geekbrain","Project":"'"$PROJECT"'"}'
TAGS_COMMA="Owner=ngokhoangnam4268@gmail.com,Environment=dev,CostCenter=G5,Application=geekbrain,Project=$PROJECT"

if [ -z "$KB_BUCKET" ] || [ -z "$ALB_DNS" ] || [ -z "$ACCOUNT_ID" ] || [ -z "$BEDROCK_KB_ID" ] || [ -z "$BEDROCK_DS_ID" ]; then
  echo "LỖI: Hãy export các biến KB_BUCKET, ALB_DNS, ACCOUNT_ID, BEDROCK_KB_ID, BEDROCK_DS_ID trước!"
  exit 1
fi

echo "=== 1. TẠO SQS (DEAD LETTER QUEUE) ==="
DLQ_URL=$(aws sqs create-queue --queue-name ${PROJECT}-dlq --query 'QueueUrl' --output text --region $REGION)
aws sqs tag-queue --queue-url $DLQ_URL --tags "$TAGS_JSON" --region $REGION || true
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text --region $REGION)

echo "=== 2. TẠO IAM ROLE & LAMBDA FUNCTION ==="
LAMBDA_ROLE="${PROJECT}-lambda-role"
aws iam create-role --role-name $LAMBDA_ROLE --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --tags $TAGS > /dev/null || true
aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole > /dev/null || true
aws iam put-role-policy --role-name $LAMBDA_ROLE --policy-name LambdaAppPolicy --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:*\",\"s3:*\",\"sqs:SendMessage\"],\"Resource\":\"*\"}]}" > /dev/null || true
sleep 10 # Đợi role propagate

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE --query 'Role.Arn' --output text)
LAMBDA_NAME="${PROJECT}-kb-sync"

# Trỏ tới file zip lambda có sẵn trong source code nhóm
LAMBDA_ZIP_PATH="/mnt/d/NamHoang/Workspace/ChuongTrinhHoc/XBrain/xbrain-g5/w5/backend/lambda/kb_auto_sync_lambda.zip"
if [ ! -f "$LAMBDA_ZIP_PATH" ]; then
    echo "Không tìm thấy $LAMBDA_ZIP_PATH. Hãy đảm bảo chạy script ở thư mục scripts/."
    exit 1
fi

aws lambda create-function \
    --function-name $LAMBDA_NAME \
    --runtime python3.11 \
    --role $LAMBDA_ROLE_ARN \
    --handler kb_auto_sync_lambda.handler \
    --timeout 60 \
    --zip-file fileb://$LAMBDA_ZIP_PATH \
    --environment "Variables={BEDROCK_KB_ID=$BEDROCK_KB_ID,BEDROCK_DS_ID=$BEDROCK_DS_ID}" \
    --tags "$TAGS_JSON" \
    --region $REGION > /dev/null || true

LAMBDA_ARN=$(aws lambda get-function --function-name $LAMBDA_NAME --query 'Configuration.FunctionArn' --output text --region $REGION)

echo "=== 3. MH5: S3 TRIGGER & ASYNC DLQ ==="
aws lambda put-function-event-invoke-config --function-name $LAMBDA_NAME --maximum-retry-attempts 0 --destination-config "{\"OnFailure\":{\"Destination\":\"$DLQ_ARN\"}}" --region $REGION > /dev/null

aws lambda add-permission --function-name $LAMBDA_NAME --principal s3.amazonaws.com --statement-id AllowS3Invoke --action "lambda:InvokeFunction" --source-arn "arn:aws:s3:::$KB_BUCKET" --region $REGION > /dev/null || true

cat <<EOF > s3-notify.json
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "$LAMBDA_ARN",
      "Events": ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"],
      "Filter": { "Key": { "FilterRules": [{ "Name": "prefix", "Value": "knowledge_base/" }] } }
    }
  ]
}
EOF
aws s3api put-bucket-notification-configuration --bucket $KB_BUCKET --notification-configuration file://s3-notify.json --region $REGION

echo "=== 4. MH4: API GATEWAY (REST API có Auth & Throttling) ==="
API_ID=$(aws apigateway create-rest-api --name ${PROJECT}-api --tags "$TAGS_JSON" --query 'id' --output text --region $REGION)
ROOT_ID=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[0].id' --output text --region $REGION)
RES_ID=$(aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_ID --path-part "sync" --query 'id' --output text --region $REGION)

aws apigateway put-method --rest-api-id $API_ID --resource-id $RES_ID --http-method POST --authorization-type NONE --api-key-required --region $REGION > /dev/null
aws apigateway put-integration --rest-api-id $API_ID --resource-id $RES_ID --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" --region $REGION > /dev/null
aws lambda add-permission --function-name $LAMBDA_NAME --principal apigateway.amazonaws.com --statement-id AllowAPIInvoke --action "lambda:InvokeFunction" --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*" --region $REGION > /dev/null || true
aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod --region $REGION > /dev/null

KEY_ID=$(aws apigateway create-api-key --name ${PROJECT}-key --enabled --tags "$TAGS_JSON" --query 'id' --output text --region $REGION)
PLAN_ID=$(aws apigateway create-usage-plan --name ${PROJECT}-plan --api-stages apiId=$API_ID,stage=prod --throttle rateLimit=10,burstLimit=20 --quota limit=1000,offset=0,period=DAY --tags "$TAGS_JSON" --query 'id' --output text --region $REGION)
aws apigateway create-usage-plan-key --usage-plan-id $PLAN_ID --key-id $KEY_ID --key-type "API_KEY" --region $REGION > /dev/null
API_KEY_VALUE=$(aws apigateway get-api-key --api-key $KEY_ID --include-value --query 'value' --output text --region $REGION)

echo "API Gateway Endpoint: https://$API_ID.execute-api.$REGION.amazonaws.com/prod/sync"
echo "API Key (Dùng làm header x-api-key): $API_KEY_VALUE"

echo "=== 5. CLOUDFRONT DISTRIBUTE CHO ALB (Tùy chọn) ==="
# Thay vì tạo Distribution bằng CLI dài dòng (rất dễ lỗi JSON), CloudFront nên trỏ vào ALB_DNS.
echo "Bạn có thể vào Console tạo CloudFront trỏ Origin về ALB: $ALB_DNS để cache frontend!"
echo "Hoàn thành toàn bộ quy trình W5!"
