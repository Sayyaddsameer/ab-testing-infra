#!/bin/bash
# init-aws.sh
#
# Provisions the entire A/B testing infrastructure inside LocalStack.
# Runs automatically via the /etc/localstack/init/ready.d/ hook.
#
# What gets built (in order):
#   1. VPC with public and private subnets across two AZs
#   2. Internet Gateway + NAT Gateway + route tables
#   3. IAM role with S3 read-only policy and an instance profile
#   4. Security groups for the ALB and the app instances
#   5. Two launch templates (one per application version)
#   6. Target groups, ALB with weighted 50/50 listener, and two ASGs
#
# Every resource ID is captured dynamically from command output.
# Nothing is hardcoded.

set -euo pipefail

# -- Configuration --
ENDPOINT="http://localhost:4566"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AZ_A="${REGION}a"
AZ_B="${REGION}b"

# Helper function so we don't have to repeat the endpoint and region everywhere
awslocal() {
    aws --endpoint-url="${ENDPOINT}" --region "${REGION}" --no-cli-pager "$@"
}

echo "Starting A/B testing infrastructure provisioning..."
echo ""


# -------------------------------------------------------
# 1. VPC and Networking
# -------------------------------------------------------

echo "-- Setting up VPC and networking --"

# Create the VPC
VPC_ID=$(awslocal ec2 create-vpc \
    --cidr-block 10.0.0.0/16 \
    --query 'Vpc.VpcId' \
    --output text)
echo "Created VPC: ${VPC_ID}"

awslocal ec2 create-tags \
    --resources "${VPC_ID}" \
    --tags Key=Name,Value=ab-test-vpc

# Turn on DNS support so instances can resolve hostnames
awslocal ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-support '{"Value": true}'
awslocal ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-hostnames '{"Value": true}'

# Public subnets -- these will hold the ALB nodes and the NAT gateway
PUBLIC_SUBNET_A=$(awslocal ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block 10.0.1.0/24 \
    --availability-zone "${AZ_A}" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created public subnet A in ${AZ_A}: ${PUBLIC_SUBNET_A}"

awslocal ec2 create-tags \
    --resources "${PUBLIC_SUBNET_A}" \
    --tags Key=Name,Value=public-subnet-a Key=Type,Value=public

PUBLIC_SUBNET_B=$(awslocal ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block 10.0.2.0/24 \
    --availability-zone "${AZ_B}" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created public subnet B in ${AZ_B}: ${PUBLIC_SUBNET_B}"

awslocal ec2 create-tags \
    --resources "${PUBLIC_SUBNET_B}" \
    --tags Key=Name,Value=public-subnet-b Key=Type,Value=public

# Instances launched in public subnets should get a public IP automatically
awslocal ec2 modify-subnet-attribute \
    --subnet-id "${PUBLIC_SUBNET_A}" \
    --map-public-ip-on-launch
awslocal ec2 modify-subnet-attribute \
    --subnet-id "${PUBLIC_SUBNET_B}" \
    --map-public-ip-on-launch

# Private subnets -- the actual application instances live here,
# away from direct internet access
PRIVATE_SUBNET_A=$(awslocal ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block 10.0.101.0/24 \
    --availability-zone "${AZ_A}" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created private subnet A in ${AZ_A}: ${PRIVATE_SUBNET_A}"

awslocal ec2 create-tags \
    --resources "${PRIVATE_SUBNET_A}" \
    --tags Key=Name,Value=private-subnet-a Key=Type,Value=private

PRIVATE_SUBNET_B=$(awslocal ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block 10.0.102.0/24 \
    --availability-zone "${AZ_B}" \
    --query 'Subnet.SubnetId' \
    --output text)
echo "Created private subnet B in ${AZ_B}: ${PRIVATE_SUBNET_B}"

awslocal ec2 create-tags \
    --resources "${PRIVATE_SUBNET_B}" \
    --tags Key=Name,Value=private-subnet-b Key=Type,Value=private

# Internet Gateway -- gives the public subnets a path to the internet
IGW_ID=$(awslocal ec2 create-internet-gateway \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

awslocal ec2 attach-internet-gateway \
    --internet-gateway-id "${IGW_ID}" \
    --vpc-id "${VPC_ID}"
echo "Created and attached Internet Gateway: ${IGW_ID}"

awslocal ec2 create-tags \
    --resources "${IGW_ID}" \
    --tags Key=Name,Value=ab-test-igw

# NAT Gateway -- lets private instances reach the internet (outbound only)
# without being directly accessible from outside
EIP_ALLOC_ID=$(awslocal ec2 allocate-address \
    --domain vpc \
    --query 'AllocationId' \
    --output text)

NAT_GW_ID=$(awslocal ec2 create-nat-gateway \
    --subnet-id "${PUBLIC_SUBNET_A}" \
    --allocation-id "${EIP_ALLOC_ID}" \
    --query 'NatGateway.NatGatewayId' \
    --output text)
echo "Created NAT Gateway: ${NAT_GW_ID} (EIP: ${EIP_ALLOC_ID})"

awslocal ec2 create-tags \
    --resources "${NAT_GW_ID}" \
    --tags Key=Name,Value=ab-test-nat-gw

# Give the NAT gateway a moment to come up
echo "Waiting for NAT Gateway to become available..."
for i in $(seq 1 30); do
    NAT_STATE=$(awslocal ec2 describe-nat-gateways \
        --nat-gateway-ids "${NAT_GW_ID}" \
        --query 'NatGateways[0].State' \
        --output text)
    if [ "${NAT_STATE}" = "available" ]; then
        echo "NAT Gateway is ready."
        break
    fi
    sleep 2
done

# Public route table -- default route goes to the Internet Gateway
PUBLIC_RT_ID=$(awslocal ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --query 'RouteTable.RouteTableId' \
    --output text)

awslocal ec2 create-tags \
    --resources "${PUBLIC_RT_ID}" \
    --tags Key=Name,Value=public-route-table

awslocal ec2 create-route \
    --route-table-id "${PUBLIC_RT_ID}" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "${IGW_ID}"

awslocal ec2 associate-route-table \
    --route-table-id "${PUBLIC_RT_ID}" \
    --subnet-id "${PUBLIC_SUBNET_A}"
awslocal ec2 associate-route-table \
    --route-table-id "${PUBLIC_RT_ID}" \
    --subnet-id "${PUBLIC_SUBNET_B}"
echo "Public route table configured: ${PUBLIC_RT_ID}"

# Private route table -- default route goes through the NAT Gateway
PRIVATE_RT_ID=$(awslocal ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --query 'RouteTable.RouteTableId' \
    --output text)

awslocal ec2 create-tags \
    --resources "${PRIVATE_RT_ID}" \
    --tags Key=Name,Value=private-route-table

awslocal ec2 create-route \
    --route-table-id "${PRIVATE_RT_ID}" \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id "${NAT_GW_ID}"

awslocal ec2 associate-route-table \
    --route-table-id "${PRIVATE_RT_ID}" \
    --subnet-id "${PRIVATE_SUBNET_A}"
awslocal ec2 associate-route-table \
    --route-table-id "${PRIVATE_RT_ID}" \
    --subnet-id "${PRIVATE_SUBNET_B}"
echo "Private route table configured: ${PRIVATE_RT_ID}"

echo ""


# -------------------------------------------------------
# 2. IAM Role and Instance Profile
# -------------------------------------------------------

echo "-- Setting up IAM --"

# Create a bucket that our IAM policy will reference.
# This is a real bucket in LocalStack -- the policy grants read access to it.
awslocal s3 mb s3://ab-test-config-bucket
echo "Created S3 bucket: ab-test-config-bucket"

# The trust policy says "EC2 instances are allowed to assume this role"
EC2_TRUST_POLICY=$(cat <<'TRUST_EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
TRUST_EOF
)

awslocal iam create-role \
    --role-name ec2-s3-read-role \
    --assume-role-policy-document "${EC2_TRUST_POLICY}" \
    --description "Allows EC2 instances to read from the ab-test-config S3 bucket"
echo "Created IAM role: ec2-s3-read-role"

# The permissions policy -- only allows reading objects from our specific bucket.
# This follows the principle of least privilege.
S3_READ_POLICY=$(cat <<'POLICY_EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::ab-test-config-bucket/*"
        }
    ]
}
POLICY_EOF
)

awslocal iam put-role-policy \
    --role-name ec2-s3-read-role \
    --policy-name s3-read-config-policy \
    --policy-document "${S3_READ_POLICY}"
echo "Attached inline policy: s3-read-config-policy"

# Instance profile -- this is how you attach an IAM role to EC2 instances.
# You can't attach a role directly; it has to go through a profile.
awslocal iam create-instance-profile \
    --instance-profile-name ec2-s3-read-profile

awslocal iam add-role-to-instance-profile \
    --instance-profile-name ec2-s3-read-profile \
    --role-name ec2-s3-read-role
echo "Created instance profile: ec2-s3-read-profile"

echo ""


# -------------------------------------------------------
# 3. Security Groups
# -------------------------------------------------------

echo "-- Setting up security groups --"

# ALB security group -- open to the world on port 80 since it's the
# public-facing entry point
ALB_SG_ID=$(awslocal ec2 create-security-group \
    --group-name alb-sg \
    --description "Security group for the Application Load Balancer - allows HTTP from anywhere" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text)
echo "Created ALB security group: ${ALB_SG_ID}"

awslocal ec2 create-tags \
    --resources "${ALB_SG_ID}" \
    --tags Key=Name,Value=alb-sg

awslocal ec2 authorize-security-group-ingress \
    --group-id "${ALB_SG_ID}" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

# App security group -- only accepts traffic from the ALB, not from
# the internet directly. This is what keeps the instances protected.
APP_SG_ID=$(awslocal ec2 create-security-group \
    --group-name app-sg \
    --description "Security group for application instances - allows HTTP only from ALB" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text)
echo "Created app security group: ${APP_SG_ID}"

awslocal ec2 create-tags \
    --resources "${APP_SG_ID}" \
    --tags Key=Name,Value=app-sg

awslocal ec2 authorize-security-group-ingress \
    --group-id "${APP_SG_ID}" \
    --protocol tcp \
    --port 80 \
    --source-group "${ALB_SG_ID}"

echo ""


# -------------------------------------------------------
# 4. Launch Templates
# -------------------------------------------------------

echo "-- Creating launch templates --"

# Try to find an Amazon Linux 2 AMI. LocalStack may or may not have one
# available, so we have a couple of fallbacks.
AMI_ID=$(awslocal ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    echo "No Amazon Linux 2 AMI found, trying any available AMI..."
    AMI_ID=$(awslocal ec2 describe-images \
        --query 'Images[0].ImageId' \
        --output text)
fi

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
    echo "No AMIs in the catalog at all, using a placeholder for LocalStack."
    AMI_ID="ami-0abcdef1234567890"
fi
echo "Using AMI: ${AMI_ID}"

# Read the user data scripts from the mounted volume and base64 encode them
USER_DATA_A=$(base64 -w 0 /opt/user-data/user_data_a.sh)
USER_DATA_B=$(base64 -w 0 /opt/user-data/user_data_b.sh)

# Launch template for version A
awslocal ec2 create-launch-template \
    --launch-template-name launch-template-a \
    --launch-template-data "{
        \"ImageId\": \"${AMI_ID}\",
        \"InstanceType\": \"t2.micro\",
        \"SecurityGroupIds\": [\"${APP_SG_ID}\"],
        \"IamInstanceProfile\": {
            \"Name\": \"ec2-s3-read-profile\"
        },
        \"UserData\": \"${USER_DATA_A}\",
        \"TagSpecifications\": [
            {
                \"ResourceType\": \"instance\",
                \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"app-version-a\"},
                    {\"Key\": \"Version\", \"Value\": \"A\"}
                ]
            }
        ]
    }"
echo "Created launch-template-a"

# Launch template for version B -- same config, different user data
awslocal ec2 create-launch-template \
    --launch-template-name launch-template-b \
    --launch-template-data "{
        \"ImageId\": \"${AMI_ID}\",
        \"InstanceType\": \"t2.micro\",
        \"SecurityGroupIds\": [\"${APP_SG_ID}\"],
        \"IamInstanceProfile\": {
            \"Name\": \"ec2-s3-read-profile\"
        },
        \"UserData\": \"${USER_DATA_B}\",
        \"TagSpecifications\": [
            {
                \"ResourceType\": \"instance\",
                \"Tags\": [
                    {\"Key\": \"Name\", \"Value\": \"app-version-b\"},
                    {\"Key\": \"Version\", \"Value\": \"B\"}
                ]
            }
        ]
    }"
echo "Created launch-template-b"

echo ""


# -------------------------------------------------------
# 5. Target Groups, ALB, and Auto Scaling Groups
# -------------------------------------------------------

echo "-- Setting up load balancing and auto scaling --"

# Target groups -- these are what the ALB forwards traffic to.
# Each one does health checks on HTTP port 80.
TG_A_ARN=$(awslocal elbv2 create-target-group \
    --name target-group-a \
    --protocol HTTP \
    --port 80 \
    --vpc-id "${VPC_ID}" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path "/" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
echo "Created target-group-a: ${TG_A_ARN}"

TG_B_ARN=$(awslocal elbv2 create-target-group \
    --name target-group-b \
    --protocol HTTP \
    --port 80 \
    --vpc-id "${VPC_ID}" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path "/" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)
echo "Created target-group-b: ${TG_B_ARN}"

# Application Load Balancer -- internet-facing, sits in the public subnets
ALB_ARN=$(awslocal elbv2 create-load-balancer \
    --name ab-test-alb \
    --type application \
    --scheme internet-facing \
    --subnets "${PUBLIC_SUBNET_A}" "${PUBLIC_SUBNET_B}" \
    --security-groups "${ALB_SG_ID}" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
echo "Created ALB: ${ALB_ARN}"

ALB_DNS=$(awslocal elbv2 describe-load-balancers \
    --load-balancer-arns "${ALB_ARN}" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
echo "ALB DNS name: ${ALB_DNS}"

# Wait for the ALB to finish provisioning
echo "Waiting for ALB to become active..."
for i in $(seq 1 30); do
    ALB_STATE=$(awslocal elbv2 describe-load-balancers \
        --load-balancer-arns "${ALB_ARN}" \
        --query 'LoadBalancers[0].State.Code' \
        --output text)
    if [ "${ALB_STATE}" = "active" ]; then
        echo "ALB is active."
        break
    fi
    sleep 2
done

# Listener on port 80 with a weighted forward rule:
# 50% of requests go to target-group-a, 50% go to target-group-b.
# This is the core of the A/B split.
LISTENER_ARN=$(awslocal elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions "[
        {
            \"Type\": \"forward\",
            \"ForwardConfig\": {
                \"TargetGroups\": [
                    {
                        \"TargetGroupArn\": \"${TG_A_ARN}\",
                        \"Weight\": 50
                    },
                    {
                        \"TargetGroupArn\": \"${TG_B_ARN}\",
                        \"Weight\": 50
                    }
                ]
            }
        }
    ]" \
    --query 'Listeners[0].ListenerArn' \
    --output text)
echo "Created listener with 50/50 weighted forwarding: ${LISTENER_ARN}"

# Look up the launch template IDs (we need these for the ASG config)
LT_A_ID=$(awslocal ec2 describe-launch-templates \
    --launch-template-names launch-template-a \
    --query 'LaunchTemplates[0].LaunchTemplateId' \
    --output text)

LT_B_ID=$(awslocal ec2 describe-launch-templates \
    --launch-template-names launch-template-b \
    --query 'LaunchTemplates[0].LaunchTemplateId' \
    --output text)

# Auto Scaling Group for version A
# Launches instances into the private subnets and registers them with target-group-a
awslocal autoscaling create-auto-scaling-group \
    --auto-scaling-group-name asg-a \
    --launch-template "LaunchTemplateId=${LT_A_ID},Version=\$Latest" \
    --min-size 1 \
    --max-size 2 \
    --desired-capacity 1 \
    --vpc-zone-identifier "${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B}" \
    --target-group-arns "${TG_A_ARN}" \
    --health-check-type ELB \
    --health-check-grace-period 60 \
    --tags "Key=Name,Value=asg-a,PropagateAtLaunch=true" \
           "Key=Version,Value=A,PropagateAtLaunch=true"
echo "Created asg-a (min=1, desired=1, max=2)"

# Auto Scaling Group for version B -- same structure, different template and target group
awslocal autoscaling create-auto-scaling-group \
    --auto-scaling-group-name asg-b \
    --launch-template "LaunchTemplateId=${LT_B_ID},Version=\$Latest" \
    --min-size 1 \
    --max-size 2 \
    --desired-capacity 1 \
    --vpc-zone-identifier "${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B}" \
    --target-group-arns "${TG_B_ARN}" \
    --health-check-type ELB \
    --health-check-grace-period 60 \
    --tags "Key=Name,Value=asg-b,PropagateAtLaunch=true" \
           "Key=Version,Value=B,PropagateAtLaunch=true"
echo "Created asg-b (min=1, desired=1, max=2)"


# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "Provisioning complete."
echo ""
echo "Resources created:"
echo "  VPC:              ${VPC_ID}"
echo "  Public subnets:   ${PUBLIC_SUBNET_A}, ${PUBLIC_SUBNET_B}"
echo "  Private subnets:  ${PRIVATE_SUBNET_A}, ${PRIVATE_SUBNET_B}"
echo "  Internet Gateway: ${IGW_ID}"
echo "  NAT Gateway:      ${NAT_GW_ID}"
echo "  ALB SG:           ${ALB_SG_ID}"
echo "  App SG:           ${APP_SG_ID}"
echo "  ALB:              ${ALB_ARN}"
echo "  ALB DNS:          ${ALB_DNS}"
echo "  Target Group A:   ${TG_A_ARN}"
echo "  Target Group B:   ${TG_B_ARN}"
echo "  Listener:         ${LISTENER_ARN}"
echo ""
echo "To test the A/B split:"
echo "  curl http://${ALB_DNS}"
