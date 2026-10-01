#!/usr/bin/env bash
# End-to-end checks of the lab. Exit code 0 only if every check passes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/versions.env
source scripts/versions.env

HOST=orders.lab.example
NETSHOOT=nicolaka/netshoot:v0.13
BUSYBOX=busybox:1.37
passed=0
failed=0
tmp=$(mktemp -d)
pf_pid=""

ok()   { printf '  PASS  %s\n' "$*"; passed=$((passed + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; failed=$((failed + 1)); }
note() { printf '  INFO  %s\n' "$*"; }
cleanup() {
  [ -n "${pf_pid}" ] && kill "${pf_pid}" 2>/dev/null
  rm -rf "${tmp}"
}
trap cleanup EXIT

echo "== Gateway"
gw_ip=$(kubectl -n gateway get gateway lab -o jsonpath='{.status.addresses[0].value}')
if [ -n "${gw_ip}" ]; then ok "Gateway is programmed with address ${gw_ip} (from the Cilium LB IPAM pool)"; else bad "Gateway has no address"; fi

kubectl -n cert-manager get secret lab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${tmp}/ca.crt"
svc=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-namespace=gateway,gateway.envoyproxy.io/owning-gateway-name=lab \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward "svc/${svc}" 18080:80 18443:443 >/dev/null 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:18080" && break; sleep 1; done

curl_gw() { # curl through the port-forward, presenting the right Host/SNI
  curl -s --cacert "${tmp}/ca.crt" --resolve "${HOST}:18443:127.0.0.1" --resolve "${HOST}:18080:127.0.0.1" "$@"
}

echo "== TLS and routing"
code=$(curl_gw -o /dev/null -w '%{http_code} %{redirect_url}' "http://${HOST}:18080/")
case "${code}" in
  "301 https://${HOST}"*) ok "HTTP redirects to HTTPS (${code})" ;;
  *) bad "HTTP should redirect to HTTPS with 301, got: ${code}" ;;
esac

body=$(curl_gw "https://${HOST}:18443/")
if echo "${body}" | grep -q '"hostname"'; then ok "HTTPS works with the lab CA and reaches the app"; else bad "HTTPS request failed: ${body:0:200}"; fi

subject=$(echo | openssl s_client -connect 127.0.0.1:18443 -servername "${HOST}" -CAfile "${tmp}/ca.crt" 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')
if echo "${subject}" | grep -q 'DNS:\*\.lab\.example'; then ok "Certificate issued by cert-manager covers *.lab.example"; else bad "Unexpected certificate SAN: ${subject}"; fi

echo "== Cilium policies"
code=$(curl_gw -o /dev/null -w '%{http_code}' "https://${HOST}:18443/env")
if [ "${code}" = "403" ]; then ok "L7 policy blocks /env through the gateway (403)"; else bad "/env should be blocked with 403, got ${code}"; fi

# The name must resolve and the connection must time out: a DNS error or a failed image pull
# would also "fail", so the error message is checked, not just the exit code.
out=$(kubectl run np-check -n default --image="${BUSYBOX}" --rm -i --restart=Never --quiet -- \
  wget -q -O /dev/null -T 5 http://orders.apps.svc.cluster.local:9898/ 2>&1)
rc=$?
if [ "${rc}" -eq 0 ]; then
  bad "A pod in another namespace reached the app directly"
elif echo "${out}" | grep -qi 'timed out'; then
  ok "Pods outside the gateway cannot reach the app directly (connection dropped by policy)"
else
  bad "Inconclusive bypass check: ${out:0:200}"
fi

echo "== Rate limit"
throttled=0
for _ in $(seq 1 40); do
  [ "$(curl_gw -o /dev/null -w '%{http_code}' "https://${HOST}:18443/version")" = "429" ] && throttled=$((throttled + 1))
done
if [ "${throttled}" -gt 0 ]; then ok "Rate limit returned 429 for ${throttled} of 40 requests"; else bad "No 429 after 40 requests"; fi

echo "== DNS (external-dns -> BIND over RFC 2136)"
answer=""
for _ in $(seq 1 12); do
  answer=$(kubectl run dns-check -n dns --image="${NETSHOOT}" --rm -i --restart=Never --quiet -- \
    dig +short @bind.dns.svc.cluster.local "${HOST}" A 2>/dev/null | tr -d '\r' | head -1)
  [ "${answer}" = "${gw_ip}" ] && break
  sleep 10
done
if [ -n "${gw_ip}" ] && [ "${answer}" = "${gw_ip}" ]; then ok "${HOST} resolves to the Gateway address ${gw_ip}"; else bad "${HOST} resolved to '${answer}', expected '${gw_ip}'"; fi

tsig=$(kubectl -n dns get secret tsig -o jsonpath='{.data.secret}' | base64 -d)
zone=$(kubectl run axfr-check -n dns --image="${NETSHOOT}" --rm -i --restart=Never --quiet -- \
  dig @bind.dns.svc.cluster.local lab.example AXFR -y "hmac-sha256:externaldns-key:${tsig}" 2>/dev/null)
if echo "${zone}" | grep -q 'heritage=external-dns,external-dns/owner=ingress-lab'; then
  ok "external-dns wrote a TXT ownership record next to the A record"
else
  bad "No external-dns ownership record found in the zone"
fi

echo "== Direct access to the LoadBalancer IP (works where the kind network is routable, e.g. Linux)"
if [ -n "${gw_ip}" ] && curl -s --max-time 5 --cacert "${tmp}/ca.crt" --resolve "${HOST}:443:${gw_ip}" \
     -o /dev/null "https://${HOST}/version"; then
  note "reached https://${HOST} on ${gw_ip} through Cilium L2 announcements"
else
  note "LoadBalancer IP not reachable from this machine (normal on macOS/Windows Docker); port-forward was used instead"
fi

printf '\n%d passed, %d failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]
