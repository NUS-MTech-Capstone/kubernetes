# Kubernetes

EKS manifests and deployment tooling for the DenDenMushi MVP.

The AWS deployment runs these services:

- Session Manager
- STS
- Proxy Control Plane
- Proxy Dataplane

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
- Cognito user pool/client
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
```

With GitHub CLI:

```bash
ROLE_ARN=$(terraform output -raw github_ecr_push_role_arn)
for repo in sts proxy-controlplane session-manager proxy-dataplane ddm-agent; do
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
3. Reads the target details from Terraform outputs.
4. Runs `ssh-keyscan` from an EKS pod.
5. Builds trusted STS inventory.
6. Renders AWS IDs and ARNs into the manifests.
7. Deploys the four services and waits for the ALB.

```bash
cd ../kubernetes
IMAGE_TAG=main ./scripts/deploy-aws.sh
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

Both API and WebSocket traffic use one Cognito-authenticated HTTPS ALB:

```text
https://api.ddm.keiyam.me/*             -> Proxy Control Plane
wss://api.ddm.keiyam.me/sessions/*/ws   -> Proxy Dataplane
```

The WebSocket rule has higher ALB group priority. Sharing a hostname lets the
browser send the Cognito ALB session cookie during the WebSocket upgrade.

## Checks

```bash
kubectl get pods,ingress -n dendenmushi
kubectl describe serviceaccount proxy-dataplane -n dendenmushi
kubectl logs deployment/proxy-dataplane -n dendenmushi
curl -I https://api.ddm.keiyam.me/healthz
```

The unauthenticated health request should redirect to Cognito.
