#!/usr/bin/env bash
# Collects what you need when something in the lab does not work.
set -uo pipefail
section() { printf '\n===== %s =====\n' "$*"; }

section "Nodes and pods"
kubectl get nodes -o wide
kubectl get pods -A -o wide

section "Gateway API objects"
kubectl get gatewayclass,gateway,httproute -A
kubectl -n gateway describe gateway lab
kubectl -n apps describe httproute orders

section "Envoy Gateway policies"
kubectl -n apps get backendtrafficpolicy orders-limits -o yaml

section "Certificates"
kubectl get certificate -A
kubectl get certificaterequest -A

section "LoadBalancer services and IP pool"
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get ciliumloadbalancerippool -o wide

section "Cilium"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief 2>/dev/null || true
kubectl get ciliumnetworkpolicy,networkpolicy -A

section "DNS"
kubectl -n dns logs deploy/external-dns --tail=50
kubectl -n dns logs deploy/bind --tail=50

section "Recent events"
kubectl get events -A --sort-by=.lastTimestamp | tail -40
