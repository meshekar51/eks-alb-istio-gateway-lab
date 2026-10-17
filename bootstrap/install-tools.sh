#!/usr/bin/env bash
# Install pinned, checksum-verified CLI tools on the Amazon Linux 2023 bastion.
#   kubectl, helm, terraform, istioctl  (+ jq, git, dig, openssl, envsubst, make)
# Usage: make tools      (or: bash bootstrap/install-tools.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
[[ -f lab.env ]] && source lab.env || source lab.env.example

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

BIN=/usr/local/bin
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "OS packages"
sudo dnf install -y git jq make tar gzip unzip gettext bind-utils openssl python3 tmux which >/dev/null

log "kubectl ${KUBECTL_VERSION}"
curl -fsSLo "$TMP/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256")  $TMP/kubectl" | sha256sum -c -
sudo install -m 0755 "$TMP/kubectl" "$BIN/kubectl"

log "helm ${HELM_VERSION}"
HELM_TGZ="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
curl -fsSLo "$TMP/$HELM_TGZ" "https://get.helm.sh/${HELM_TGZ}"
echo "$(curl -fsSL "https://get.helm.sh/${HELM_TGZ}.sha256sum" | awk '{print $1}')  $TMP/$HELM_TGZ" | sha256sum -c -
tar -xzf "$TMP/$HELM_TGZ" -C "$TMP"
sudo install -m 0755 "$TMP/linux-${ARCH}/helm" "$BIN/helm"

log "terraform ${TERRAFORM_VERSION}"
TF_ZIP="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"
curl -fsSLo "$TMP/$TF_ZIP" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TF_ZIP}"
curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
  | grep " ${TF_ZIP}\$" | sed "s|${TF_ZIP}|$TMP/${TF_ZIP}|" | sha256sum -c -
unzip -oq "$TMP/$TF_ZIP" -d "$TMP"
sudo install -m 0755 "$TMP/terraform" "$BIN/terraform"

log "istioctl ${ISTIO_VERSION}"
IST_TGZ="istioctl-${ISTIO_VERSION}-linux-${ARCH}.tar.gz"
curl -fsSLo "$TMP/$IST_TGZ" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${IST_TGZ}"
echo "$(curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${IST_TGZ}.sha256" | awk '{print $1}')  $TMP/$IST_TGZ" | sha256sum -c -
tar -xzf "$TMP/$IST_TGZ" -C "$TMP"
sudo install -m 0755 "$TMP/istioctl" "$BIN/istioctl"

log "shell niceties (~/.bashrc)"
if ! grep -q "# istio-lab" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc <<'EOF'
# istio-lab
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
source <(helm completion bash)
source <(istioctl completion bash) 2>/dev/null || true
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
EOF
fi

log "Versions"
aws --version
kubectl version --client=true | head -1
helm version --short
terraform version | head -1
istioctl version --remote=false

log "AWS identity (must be the bastion role)"
aws sts get-caller-identity
echo "Bastion public IP (EKS allow-list): $(curl -4fsS https://checkip.amazonaws.com)"
echo
echo "Next: edit lab.env (DOMAIN, HOSTED_ZONE) then run:  make infra"
