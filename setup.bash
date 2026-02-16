#!/bin/bash
set -e
kind delete clusters mein-cluster || true
cat <<EOF | kind create cluster --name mein-cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
EOF
sleep 10
helm install multi-juicer oci://ghcr.io/juice-shop/multi-juicer/helm/multi-juicer -f values.yaml
sleep 10
kubectl get secrets balancer-secret -o=jsonpath='{.data.adminPassword}' | base64 --decode

# Create the loadbalancer
# This might take a couple of minutes
kubectl apply -f k8s-juice-service.yaml

# If it takes longer than a few minutes take a detailed look at the loadbalancer
kubectl describe svc multi-juicer-loadbalancer


kubectl apply -f deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-juicer-ingress
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: balancer
            port:
              number: 8080
EOF

