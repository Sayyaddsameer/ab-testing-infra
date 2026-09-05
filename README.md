# AWS A/B Testing Platform Infrastructure

This project builds a complete AWS network infrastructure for A/B testing, all running locally inside LocalStack. It provisions a VPC with public and private subnets, an Application Load Balancer that splits traffic 50/50 between two application versions, Auto Scaling Groups that keep the instances running, and IAM roles that follow least-privilege access. Everything is automated through a single shell script that runs when the container starts.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Verification Guide](#verification-guide)
- [Troubleshooting](#troubleshooting)
- [Environment Variables](#environment-variables)

---

## Architecture Overview

```
+---------------------------------------------------------------------------------+
|                        LocalStack (Simulated AWS Cloud)                         |
|  +-----------------------------------------------------------------------+      |
|  |                         VPC (10.0.0.0/16)                             |      |
|  |                                                                       |      |
|  |  +-------------------------+  +--------------------------+            |      |
|  |  | Public Subnet AZ-A      |  | Public Subnet AZ-B       |            |      |
|  |  | 10.0.1.0/24             |  | 10.0.2.0/24              |            |      |
|  |  |  +-------------------+  |  |  +--------------------+  |            |      |
|  |  |  |    ALB Node        |  |  |  |    ALB Node         |  |            |      |
|  |  |  +-------------------+  |  |  +--------------------+  |            |      |
|  |  |  +-------------------+  |  |                          |            |      |
|  |  |  |   NAT Gateway      |  |  |                          |            |      |
|  |  |  +-------------------+  |  |                          |            |      |
|  |  +-------------------------+  +--------------------------+            |      |
|  |                                                                       |      |
|  |  +-------------------------+  +--------------------------+            |      |
|  |  | Private Subnet AZ-A     |  | Private Subnet AZ-B      |            |      |
|  |  | 10.0.101.0/24           |  | 10.0.102.0/24            |            |      |
|  |  |  +--------+ +--------+  |  |  +--------+ +--------+  |            |      |
|  |  |  | Ver. A  | | Ver. B |  |  |  | Ver. A | | Ver. B |  |            |      |
|  |  |  | (ASG-A) | | (ASG-B)|  |  |  |(ASG-A) | |(ASG-B) |  |            |      |
|  |  |  +--------+ +--------+  |  |  +--------+ +--------+  |            |      |
|  |  +-------------------------+  +--------------------------+            |      |
|  +-----------------------------------------------------------------------+      |
+---------------------------------------------------------------------------------+

Traffic flow:  User -> ALB (50/50 split) -> Target Group A / Target Group B -> EC2 Instances
```

Here is a quick summary of what each piece does:

| Component | What it does |
|-----------|-------------|
| **VPC** (10.0.0.0/16) | The isolated network that contains everything |
| **Public Subnets** (2) | Hold the ALB and NAT Gateway; they have internet access |
| **Private Subnets** (2) | Hold the actual application instances, hidden from the internet |
| **Internet Gateway** | Gives public subnets two-way internet connectivity |
| **NAT Gateway** | Lets private instances make outbound requests without being exposed |
| **ALB** | Receives all incoming traffic and splits it 50/50 between versions |
| **Target Groups** (2) | Health-check the instances and receive forwarded traffic |
| **Auto Scaling Groups** (2) | Keep the right number of instances running for each version |
| **Launch Templates** (2) | Define how each version's instances should be configured |
| **IAM Role** | Gives instances read-only access to a specific S3 bucket |
| **Security Groups** (2) | ALB is open on port 80; app instances only accept traffic from the ALB |

---

## Prerequisites

You will need the following installed on your machine:

- **Docker** (v20.10 or later) and **Docker Compose** (v2.0 or later)
- **AWS CLI** (v2) for running the verification commands from your host
- **curl** for testing the traffic split

---

## Project Structure

```
ab-testing-infra/
  docker-compose.yml      - Defines the LocalStack container
  init-aws.sh             - Provisions all the AWS resources on startup
  user_data_a.sh          - Bootstrap script for Version A instances
  user_data_b.sh          - Bootstrap script for Version B instances
  .env.example            - Documents the environment variables
  README.md               - You are here
```

---

## Quick Start

1. Copy the environment file and (optionally) tweak the values:

```bash
cd ab-testing-infra
cp .env.example .env
```

2. Start LocalStack. The infrastructure will be provisioned automatically:

```bash
docker-compose up
```

Watch the logs. When you see `Provisioning complete.` the setup is done.

3. Test the A/B split:

```bash
ALB_DNS=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-load-balancers \
    --query 'LoadBalancers[0].DNSName' --output text)

for i in $(seq 1 20); do
    curl -s "http://${ALB_DNS}"
    echo ""
done
```

You should see a mix of `Version A` and `Version B` responses, roughly half and half.

4. To tear everything down:

```bash
docker-compose down -v
```

---

## How It Works

### Network layout

The VPC has a 10.0.0.0/16 CIDR block with four subnets spread across two availability zones:

| Subnet | CIDR | AZ | Type | Used for |
|--------|------|----|------|----------|
| public-subnet-a | 10.0.1.0/24 | us-east-1a | Public | ALB node, NAT Gateway |
| public-subnet-b | 10.0.2.0/24 | us-east-1b | Public | ALB node |
| private-subnet-a | 10.0.101.0/24 | us-east-1a | Private | App instances |
| private-subnet-b | 10.0.102.0/24 | us-east-1b | Private | App instances |

The public subnets have a route table that sends internet-bound traffic (0.0.0.0/0) to the Internet Gateway. The private subnets route that same traffic through the NAT Gateway instead, which means the instances can pull updates but nobody can reach them directly from outside.

### Security

The security setup follows the principle of least privilege:

- The ALB security group (alb-sg) accepts HTTP traffic on port 80 from anywhere, since it is the public entry point.
- The app security group (app-sg) only accepts HTTP on port 80 from the ALB security group. No other traffic can reach the instances.
- The IAM role (ec2-s3-read-role) grants instances just s3:GetObject on a single bucket. Nothing more.

### Traffic splitting

The ALB listener on port 80 has a weighted forward action that sends 50% of requests to target-group-a and 50% to target-group-b. Each target group is backed by its own Auto Scaling Group running the corresponding application version.

### Auto scaling

Both ASGs are configured the same way: minimum 1 instance, desired 1, maximum 2. They use ELB health checks with a 60-second grace period, so instances get some time to boot and start serving before the health check kicks in.

---

## Verification Guide

After `docker-compose up` finishes, you can verify each piece of the infrastructure.

### VPC

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-vpcs \
    --filters "Name=cidr,Values=10.0.0.0/16" \
    --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock}'
```

### Subnets

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-subnets \
    --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Tags:Tags}'
```

### Route tables

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-route-tables \
    --query 'RouteTables[*].{ID:RouteTableId,Routes:Routes,Associations:Associations}'
```

### Internet and NAT Gateways

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-internet-gateways

aws --endpoint-url=http://localhost:4566 ec2 describe-nat-gateways \
    --query 'NatGateways[*].{ID:NatGatewayId,SubnetId:SubnetId,State:State}'
```

### IAM role

```bash
# The role and its trust policy
aws --endpoint-url=http://localhost:4566 iam get-role \
    --role-name ec2-s3-read-role

# The attached permissions
aws --endpoint-url=http://localhost:4566 iam get-role-policy \
    --role-name ec2-s3-read-role \
    --policy-name s3-read-config-policy

# The instance profile
aws --endpoint-url=http://localhost:4566 iam get-instance-profile \
    --instance-profile-name ec2-s3-read-profile
```

### Security groups

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-security-groups \
    --filters "Name=group-name,Values=alb-sg,app-sg" \
    --query 'SecurityGroups[*].{Name:GroupName,ID:GroupId,Ingress:IpPermissions}'
```

Check that alb-sg allows port 80 from 0.0.0.0/0, and that app-sg allows port 80 only from the alb-sg group ID.

### Launch templates

```bash
aws --endpoint-url=http://localhost:4566 ec2 describe-launch-templates

# Check the user data for version A (should contain "Version A" when decoded)
aws --endpoint-url=http://localhost:4566 ec2 describe-launch-template-versions \
    --launch-template-name launch-template-a \
    --versions "\$Latest" \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
    --output text | base64 -d
```

### Auto Scaling Groups

```bash
aws --endpoint-url=http://localhost:4566 autoscaling describe-auto-scaling-groups \
    --query 'AutoScalingGroups[*].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,LT:LaunchTemplate,TGs:TargetGroupARNs,Subnets:VPCZoneIdentifier}'
```

### ALB, listener, and rules

```bash
aws --endpoint-url=http://localhost:4566 elbv2 describe-load-balancers

ALB_ARN=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-load-balancers \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws --endpoint-url=http://localhost:4566 elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}"

LISTENER_ARN=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" \
    --query 'Listeners[0].ListenerArn' --output text)

aws --endpoint-url=http://localhost:4566 elbv2 describe-rules \
    --listener-arn "${LISTENER_ARN}"
```

### Target health

```bash
TG_A_ARN=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-target-groups \
    --names target-group-a --query 'TargetGroups[0].TargetGroupArn' --output text)

TG_B_ARN=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-target-groups \
    --names target-group-b --query 'TargetGroups[0].TargetGroupArn' --output text)

aws --endpoint-url=http://localhost:4566 elbv2 describe-target-health \
    --target-group-arn "${TG_A_ARN}"

aws --endpoint-url=http://localhost:4566 elbv2 describe-target-health \
    --target-group-arn "${TG_B_ARN}"
```

### A/B traffic split test

```bash
ALB_DNS=$(aws --endpoint-url=http://localhost:4566 elbv2 describe-load-balancers \
    --query 'LoadBalancers[0].DNSName' --output text)

echo "Sending 20 requests to the ALB..."
for i in $(seq 1 20); do
    curl -s "http://${ALB_DNS}"
    echo ""
done | sort | uniq -c
```

You should see roughly 10 responses for each version. Anywhere between 8 and 12 for each is normal since load balancing has some randomness to it.

---

## Troubleshooting

**LocalStack won't start**

Make sure Docker is running and nothing else is using port 4566. You can check with `docker ps` and `netstat -an | grep 4566`. LocalStack needs at least 2GB of RAM.

**The init script fails partway through**

The most common cause on Windows is line endings. The script needs Unix-style line endings (LF), not Windows-style (CRLF). You can fix this with `dos2unix init-aws.sh` or by configuring your editor. Also make sure the script is executable: `chmod +x init-aws.sh`. Check the full logs with `docker-compose logs localstack`.

**Instances are not becoming healthy**

A few things to look at: first, make sure the app-sg security group allows traffic from alb-sg on port 80. Second, check that the private subnets have a route to the NAT Gateway. Third, confirm that the user data scripts actually start the web server on port 80.

**No response from the ALB endpoint**

Give it 30 to 60 seconds after provisioning finishes for the instances to boot and register. Make sure the ALB is in the active state. If it is, check the target group health to see whether any instances have registered.

---

## Environment Variables

| Variable | Default | What it controls |
|----------|---------|-----------------|
| `AWS_DEFAULT_REGION` | `us-east-1` | The AWS region for all resources |
| `AWS_ACCESS_KEY_ID` | `test` | Placeholder credential for LocalStack |
| `AWS_SECRET_ACCESS_KEY` | `test` | Placeholder credential for LocalStack |
| `SERVICES` | `ec2,elbv2,autoscaling,iam,s3,sts` | Which AWS services LocalStack should start |
| `DEBUG` | `0` | Set to 1 for verbose LocalStack logging |
| `LOCALSTACK_AUTH_TOKEN` | (empty) | Only needed for LocalStack Pro features |

---

## License

This project is for educational and demonstration purposes.
