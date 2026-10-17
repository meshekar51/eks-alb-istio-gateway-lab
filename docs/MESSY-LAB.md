# The messy lab (no spoilers)

## Story
Monday morning. Over the weekend three teams made "small changes" to the cluster:
the **platform** team, the **app** team and the **security** team. Nobody wrote anything down.

* "The shop is down."
* "The canary never gets traffic."
* "Security says the mesh isn't enforcing mTLS."

There are **15 planted faults**, spread over every layer of docs/MASTER-TROUBLESHOOTING.md. They are layered on
purpose: fixing a low layer reveals the next fault above it — exactly like a real incident.

## Rules of engagement
1. Don't read `messy/break-everything.sh` or `docs/MESSY-ANSWER-KEY.md` (spoilers).
2. Start from **symptoms**: `make test`, the browser, `curl -sv`.
3. Before each fix: `make evidence LABEL=<short-name>`. Write one line in your notebook:
   *symptom → evidence → root cause → fix*.
4. Fix in the **source of truth** where one exists (Terraform for AWS, git for manifests, Helm values for charts).
   A live `kubectl edit` is fine to *prove* a hypothesis — then make it permanent.
5. Use `make messy-score` to see how many faults remain per layer.

## Flow
```bash
make test                 # baseline green first!
make evidence LABEL=golden
make messy                # plant the faults (asks for confirmation)
make test                 # what users see
make doctor               # hop-by-hop evidence
make messy-score          # 0/15 fixed …
# … troubleshoot …
make messy-score          # 15/15
make test                 # all layers green again
```

## Hints by layer (read only the one you're stuck on)
<details><summary>L1 controllers (2 faults)</summary>

* A controller that "runs fine" can still have no permissions. Which IAM identity is it actually using?
* A controller that never logs an error can still do nothing. Does it think your zone is in scope?
</details>
<details><summary>L3 ALB (4 faults)</summary>

* The LBC tells you exactly why it can't build an ALB — in Ingress **events**. Fix them one at a time.
* An ALB in one AZ is not an ALB.
* "Works with `-k`" is not "works".
* All targets unhealthy but the site loads? Read about ALB fail-open.
</details>
<details><summary>L4 Gateway (1 fault)</summary>

* Look at `attachedRoutes` and at who is *allowed* to attach.
</details>
<details><summary>L5 HTTPRoutes (3 faults)</summary>

* `kubectl get httproute -A` — is every route one you expect? Which one is older?
* Compare what a path rule sends to the backend with what the backend serves.
* Header names: read them letter by letter.
</details>
<details><summary>L6 backends (2 faults)</summary>

* "Service exists" ≠ "Service has endpoints". Compare selectors and pod labels — exactly.
* A port number in a route is a *Service* port.
</details>
<details><summary>L7 mesh (3 faults)</summary>

* Labels are exact strings. And injection happens at pod creation.
* A pod can opt itself *out* of ambient.
* A waypoint label must name a waypoint that exists.
</details>

## When you're done
* `make test` is green and `make messy-score` shows 15/15.
* Delete the imported certificate the score script mentions.
* Compare your notebook with docs/MESSY-ANSWER-KEY.md. For each fault ask: *which automated check would have
  caught this before users did?* (Most are already in `tests/` and `tools/doctor.sh` — that is the point.)
