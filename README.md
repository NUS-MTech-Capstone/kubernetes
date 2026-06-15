# Kubernetes

EKS manifests and deployment tooling for the DenDenMushi MVP.

The AWS deployment runs these services:

- Session Manager
- STS
- Proxy Control Plane
- Proxy Dataplane
- Incident Agent
- Nest Backend
- Angular

DDM Agent remains reserved and is not deployed in the SSH-only path.

## AWS Prerequisites

Apply the main infrastructure and target host first:

```bash
cd ../aws-terraform
aws sts get-caller-identity
terraform init -reconfigure
terraform apply -var-file=secrets.tfvars

cd ../target-hosts-setup
./scripts/bootstrap.sh -auto-approve
```

The first infrastructure apply creates:

- EKS and the AWS Load Balancer Controller
- ECR repositories
- GitHub Actions ECR push role
- Proxy Dataplane IRSA role
- Nest Backend IRSA role
- Cognito user pool/client
- Dedicated web application database credentials
- Regional ACM certificate for `api.ddm.keiyam.me`

If a GitHub OIDC provider already exists in the AWS account, set its ARN instead
of creating another provider:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var='github_oidc_provider_arn=arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'
```

## Build and Push Images

Get the role created for GitHub Actions:

```bash
cd ../aws-terraform
terraform output -raw github_ecr_push_role_arn
```

Set that value as the `AWS_ROLE_ARN` Actions secret in these repositories:

```text
NUS-MTech-Capstone/sts
NUS-MTech-Capstone/proxy-controlplane
NUS-MTech-Capstone/session-manager
NUS-MTech-Capstone/proxy-dataplane
NUS-MTech-Capstone/ddm-agent
NUS-MTech-Capstone/incident-agent
NUS-MTech-Capstone/nest-backend
NUS-MTech-Capstone/angular
```

With GitHub CLI:

```bash
ROLE_ARN=$(terraform output -raw github_ecr_push_role_arn)
for repo in sts proxy-controlplane session-manager proxy-dataplane ddm-agent incident-agent nest-backend angular; do
  gh secret set AWS_ROLE_ARN --repo "NUS-MTech-Capstone/${repo}" --body "${ROLE_ARN}"
done
```

Push each service’s `main` branch or run its `Image` workflow manually. Each
workflow publishes both the immutable commit SHA and the `main` tag. Verify:

```bash
aws ecr describe-images \
  --region ap-southeast-1 \
  --repository-name dendenmushi/proxy-dataplane \
  --query 'imageDetails[].imageTags'
```

## Deploy

The deploy script:

1. Configures `kubectl`.
2. Creates or preserves the STS JWT signing secret.
3. Bootstraps the `ddm_webapp` database and least-privilege login.
4. Reads the target details from Terraform outputs.
5. Runs `ssh-keyscan` from an EKS pod.
6. Builds trusted STS inventory.
7. Discovers the Kubernetes-created ALB ARN for JWT verification.
8. Runs the Nest migration Job before the backend rollout.
9. Renders AWS IDs, ARNs, and explicit image tags into the manifests.
10. Deploys all services and waits for each rollout.

```bash
cd ../kubernetes
IMAGE_TAG=main ./scripts/deploy-aws.sh
```

For immutable, independently promoted images, set:

```bash
SESSION_MANAGER_IMAGE_TAG=<sha> \
STS_IMAGE_TAG=<sha> \
PROXY_DATAPLANE_IMAGE_TAG=<sha> \
PROXY_CONTROLPLANE_IMAGE_TAG=<sha> \
INCIDENT_AGENT_IMAGE_TAG=<sha> \
NEST_BACKEND_IMAGE_TAG=<sha> \
ANGULAR_IMAGE_TAG=<sha> \
./scripts/deploy-aws.sh
```

To explicitly supply the JWT signing key:

```bash
JWT_SIGNING_KEY=$(openssl rand -base64 48) \
IMAGE_TAG=main \
./scripts/deploy-aws.sh
```

After the script prints the ALB DNS name, perform the second Terraform apply:

```bash
cd ../aws-terraform
terraform apply \
  -var-file=secrets.tfvars \
  -var='application_alb_dns_name=<ALB DNS name>'
```

This creates the Route 53 ALB alias for `api.ddm.keiyam.me`.

## Ingress

Static content, APIs, and WebSockets use one HTTPS ALB:

```text
https://api.ddm.keiyam.me/                    -> Angular
https://api.ddm.keiyam.me/ddm/auth/login      -> Nest Backend with ALB login
https://api.ddm.keiyam.me/ddm/*               -> Nest Backend
https://api.ddm.keiyam.me/sessions/*          -> Proxy Control Plane
wss://api.ddm.keiyam.me/sessions/*/ws         -> Proxy Dataplane
https://api.ddm.keiyam.me/incidents*          -> Incident Agent
```

The WebSocket rule has higher ALB group priority. Sharing a hostname lets the
browser send the Cognito ALB session cookie during the WebSocket upgrade.

## Checks

```bash
kubectl get pods,ingress -n dendenmushi
kubectl describe serviceaccount proxy-dataplane -n dendenmushi
kubectl logs deployment/proxy-dataplane -n dendenmushi
curl -fsS https://api.ddm.keiyam.me/healthz
```

The root and Angular health endpoint are public. Data and control routes require
the ALB Cognito session.
