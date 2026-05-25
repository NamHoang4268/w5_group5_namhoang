#!/bin/bash
set -e

REGION="ap-southeast-1"
PROJECT="xbrain-w5"
AZ="${REGION}a"

# Tagging Strategy consistent with W6
TAGS="Key=Owner,Value=ngokhoangnam4268@gmail.com Key=Environment,Value=dev Key=CostCenter,Value=G5 Key=Application,Value=geekbrain Key=Project,Value=$PROJECT"

echo "=== 1. TẠO VPC & SUBNETS (SINGLE-AZ) ==="
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --region $REGION)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$PROJECT-vpc $TAGS --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION
echo "VPC_ID: $VPC_ID"

PUB_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone $AZ --query 'Subnet.SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PUB_SUBNET --tags Key=Name,Value=$PROJECT-public-subnet $TAGS --region $REGION
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch --region $REGION

PRIV_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 --availability-zone $AZ --query 'Subnet.SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PRIV_SUBNET --tags Key=Name,Value=$PROJECT-private-subnet $TAGS --region $REGION
echo "PUB_SUBNET: $PUB_SUBNET | PRIV_SUBNET: $PRIV_SUBNET"

echo "=== 2. IGW & NAT GATEWAY ==="
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text --region $REGION)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=$PROJECT-igw $TAGS --region $REGION

EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region $REGION)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET --allocation-id $EIP_ALLOC --query 'NatGateway.NatGatewayId' --output text --region $REGION)
aws ec2 create-tags --resources $NAT_ID --tags Key=Name,Value=$PROJECT-nat $TAGS --region $REGION
echo "Đang đợi NAT Gateway active (có thể mất 1-2 phút)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID --region $REGION
echo "NAT Gateway đã sẵn sàng: $NAT_ID"

echo "=== 3. ROUTE TABLES ==="
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text --region $REGION)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET --region $REGION > /dev/null
aws ec2 create-tags --resources $PUB_RT --tags Key=Name,Value=$PROJECT-public-rt $TAGS --region $REGION

PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text --region $REGION)
aws ec2 create-route --route-table-id $PRIV_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID --region $REGION > /dev/null
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET --region $REGION > /dev/null
aws ec2 create-tags --resources $PRIV_RT --tags Key=Name,Value=$PROJECT-private-rt $TAGS --region $REGION

echo "=== 4. GATEWAY ENDPOINTS (S3, DynamoDB) ==="
S3_EP=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$REGION.s3 --route-table-ids $PRIV_RT --query 'VpcEndpoint.VpcEndpointId' --output text --region $REGION)
DDB_EP=$(aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$REGION.dynamodb --route-table-ids $PRIV_RT --query 'VpcEndpoint.VpcEndpointId' --output text --region $REGION)
aws ec2 create-tags --resources $S3_EP $DDB_EP --tags Key=Name,Value=$PROJECT-gateway-endpoints $TAGS --region $REGION

echo "=== 5. MH2: NETWORK ACL (NACL) ==="
NACL_ID=$(aws ec2 create-network-acl --vpc-id $VPC_ID --query 'NetworkAcl.NetworkAclId' --output text --region $REGION)
aws ec2 create-tags --resources $NACL_ID --tags Key=Name,Value=$PROJECT-private-nacl $TAGS --region $REGION
# Allow all inbound & outbound first
aws ec2 create-network-acl-entry --network-acl-id $NACL_ID --rule-number 100 --protocol -1 --rule-action allow --ingress --cidr-block 0.0.0.0/0 --region $REGION > /dev/null
aws ec2 create-network-acl-entry --network-acl-id $NACL_ID --rule-number 100 --protocol -1 --rule-action allow --egress --cidr-block 0.0.0.0/0 --region $REGION > /dev/null
# Block 22 & 3389
aws ec2 create-network-acl-entry --network-acl-id $NACL_ID --rule-number 50 --protocol tcp --rule-action deny --ingress --cidr-block 0.0.0.0/0 --port-range From=22,To=22 --region $REGION > /dev/null
aws ec2 create-network-acl-entry --network-acl-id $NACL_ID --rule-number 51 --protocol tcp --rule-action deny --ingress --cidr-block 0.0.0.0/0 --port-range From=3389,To=3389 --region $REGION > /dev/null
# Replace default NACL for Private Subnet
aws ec2 replace-network-acl-association --association-id $(aws ec2 describe-network-acls --filters Name=vpc-id,Values=$VPC_ID Name=association.subnet-id,Values=$PRIV_SUBNET --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' --output text --region $REGION) --network-acl-id $NACL_ID --region $REGION > /dev/null

echo "=== 6. MH1: VPC FLOW LOGS ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FLOWLOGS_BUCKET="$PROJECT-flowlogs-sg-$ACCOUNT_ID"
aws s3api create-bucket --bucket $FLOWLOGS_BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION > /dev/null || true
aws s3api put-bucket-tagging --bucket $FLOWLOGS_BUCKET --tagging "TagSet=[{Key=Owner,Value=ngokhoangnam4268@gmail.com},{Key=Environment,Value=dev},{Key=CostCenter,Value=G5},{Key=Application,Value=geekbrain},{Key=Project,Value=$PROJECT}]" --region $REGION > /dev/null || true
aws ec2 create-flow-logs --resource-type VPC --resource-ids $VPC_ID --traffic-type ALL --log-destination-type s3 --log-destination "arn:aws:s3:::$FLOWLOGS_BUCKET" --region $REGION > /dev/null
echo "VPC Flow Logs lưu tại: s3://$FLOWLOGS_BUCKET"

echo "=== 7. SECURITY GROUPS ==="
ALB_SG=$(aws ec2 create-security-group --group-name $PROJECT-alb-sg --description "ALB SG" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION > /dev/null
aws ec2 create-tags --resources $ALB_SG --tags Key=Name,Value=$PROJECT-alb-sg $TAGS --region $REGION

ECS_SG=$(aws ec2 create-security-group --group-name $PROJECT-ecs-sg --description "ECS SG" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
aws ec2 authorize-security-group-ingress --group-id $ECS_SG --protocol tcp --port 8001 --source-group $ALB_SG --region $REGION > /dev/null
aws ec2 create-tags --resources $ECS_SG --tags Key=Name,Value=$PROJECT-ecs-sg $TAGS --region $REGION

EFS_SG=$(aws ec2 create-security-group --group-name $PROJECT-efs-sg --description "EFS SG" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
aws ec2 authorize-security-group-ingress --group-id $EFS_SG --protocol tcp --port 2049 --source-group $ECS_SG --region $REGION > /dev/null
aws ec2 create-tags --resources $EFS_SG --tags Key=Name,Value=$PROJECT-efs-sg $TAGS --region $REGION

echo "---"
echo "LƯU LẠI CÁC GIÁ TRỊ NÀY CHO CÁC SCRIPT SAU:"
echo "export VPC_ID=$VPC_ID"
echo "export PUB_SUBNET=$PUB_SUBNET"
echo "export PRIV_SUBNET=$PRIV_SUBNET"
echo "export ALB_SG=$ALB_SG"
echo "export ECS_SG=$ECS_SG"
echo "export EFS_SG=$EFS_SG"
echo "export ACCOUNT_ID=$ACCOUNT_ID"
echo "---"
