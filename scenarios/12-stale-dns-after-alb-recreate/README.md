# 12 — Stale DNS after the ALB is re-created

| | |
|---|---|
| Break | `bash scenarios/12-stale-dns-after-alb-recreate/break.sh` |
| Layer | L2 |
| User symptom | Browser: site unreachable / DNS error. But `curl --connect-to shop.<DOMAIN>:443:<NEW-ALB>:443 https://shop.<DOMAIN>/` works. |

## The isolation trick
`--connect-to` (or `--resolve`) lets you test **TLS + ALB + gateway + routes** with DNS taken out of the equation.
If that works and the normal URL does not → it's DNS. Then ask the **authoritative** server, not your resolver:

```bash
NS=$(dig +short NS <HOSTED_ZONE> | head -1)
dig +short @"$NS" shop.<DOMAIN>          # what Route 53 says right now
dig +short shop.<DOMAIN>                 # what your resolver cached
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> --query "ResourceRecordSets[?Name=='shop.<DOMAIN>.']"
```
An ALIAS pointing at a load balancer that no longer exists returns no usable answer.

## Fix
`bash scenarios/12-stale-dns-after-alb-recreate/fix.sh` (ExternalDNS owns the record via its TXT registry and UPSERTs it).
Negative answers can be cached by resolvers for the zone's SOA minimum TTL — be patient, test authoritative.
