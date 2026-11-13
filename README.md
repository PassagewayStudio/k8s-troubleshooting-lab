# k8s-troubleshooting-lab

A local Kubernetes lab (kind) where I reproduced six common failure modes on purpose, diagnosed each with `kubectl get/describe/logs/events`, and wrote a runbook for each: symptom, commands, root cause, fix.

All six scenarios were run on a real kind cluster, and the runbooks contain the actual command output.

## Setup
Requires Docker, [kind](https://kind.sigs.k8s.io/), and kubectl.

```
./lab.sh up         # create the kind cluster
./lab.sh baseline   # deploy the known-good db + web into namespace "lab"
./lab.sh status     # pods, services, PVCs, endpoints
./lab.sh reset      # remove scenario resources, keep the baseline
./lab.sh down       # delete the cluster
```

The baseline is a known-good Postgres (with a PVC) and a 2-replica nginx web tier in namespace `lab`, reachable at http://localhost:8080 (NodePort 30080). Credentials in the manifests are lab-only placeholders; keep real secrets out of this repo.

`lab.sh` is a bash script, so run it from Git Bash on Windows, or from WSL, macOS or Linux. Plain PowerShell will open the file in an editor instead of running it; there, run the equivalent `kubectl` / `kind` commands directly (they are short and visible inside `lab.sh`).

To reproduce a scenario, apply its **broken** manifest from `broken/`, then diagnose before looking at the fix. The versions in `scenarios/` are the fixed ones.

## Scenarios
| # | Failure | Key signal | Runbook |
|---|---------|-----------|---------|
| 1 | Bad image tag | `ErrImagePull` / `ImagePullBackOff` | [runbook](runbooks/01-imagepullbackoff.md) |
| 2 | Missing config (no DB password) | `CrashLoopBackOff`, exit code 1, cause in `logs` | [runbook](runbooks/02-crashloopbackoff.md) |
| 3 | Failing readiness probe | `Running` but `0/1` Ready, probe 404, empty endpoints | [runbook](runbooks/03-readiness-probe-failing.md) |
| 4 | Memory limit too low | `OOMKilled`, exit code 137 | [runbook](runbooks/04-oomkilled.md) |
| 5 | Wrong Service selector | Healthy pods, endpoints `<none>` | [runbook](runbooks/05-service-selector-mismatch.md) |
| 6 | Missing PVC | `Pending`, `FailedScheduling` | [runbook](runbooks/06-missing-pvc.md) |

## What broke and how I fixed it

**1. ImagePullBackOff.** A Deployment used `nginx:1.27-doesnotexist`. `describe pod` Events showed `Failed to pull image ... not found`. I changed the tag to `nginx:1.27-alpine`. My first fix used `postgres:16-alpine`, copied from the wrong baseline file. The pull error went away but the pod moved to a crash loop, because the database image ran in a container meant for nginx. Checking the pod after the fix caught it.

**2. CrashLoopBackOff.** A Postgres container had no `POSTGRES_PASSWORD`. `describe` showed only exit code 1 and the restart count. `kubectl logs` showed the real reason: the image refuses to initialize without a superuser password. I added the variable from the `db-credentials` Secret and the pod went `1/1 Running`.

**3. Failing readiness probe.** The pod was `Running` with 0 restarts but `0/1` Ready. The Events showed `Readiness probe failed: HTTP probe failed with statuscode: 404`, and the Service had no endpoints. The probe checked `/healthz`, which nginx doesn't serve. I pointed the probe at `/` and the pod became Ready and appeared in the endpoints. A failing readiness probe doesn't restart the container; it only removes the pod from the Service.

**4. OOMKilled.** The container allocated about 150M against a 50Mi limit. The status flipped between `OOMKilled`, `CrashLoopBackOff` and briefly `Running`. The cause was in the container's Last State (`Reason: OOMKilled`, exit code 137), not in the Events. I raised the limit to 200Mi and the pod stayed up with no restarts. Exit code 137 separates this from the config crash in scenario 2, which exits 1.

**5. Service selector mismatch.** The pods were healthy and labelled `app=web`, but the Service selected `app=web-app`, so its endpoints were `<none>` with no errors anywhere. I compared `get pods --show-labels` against `get svc -o wide` and fixed the selector. Empty endpoints with healthy pods points to the selector. With unready pods (scenario 3), it points to the probe.

**6. Missing PVC.** The pod stayed `Pending` with `Node: <none>`, and the Event said `persistentvolumeclaim "db-data-missing" not found`. Pointing `claimName` at the existing `db-data` let the pod schedule, but it then crash-looped. That volume belongs to the baseline database, so sharing it was the wrong fix. Changing `claimName` to another name that didn't exist yet just moved the problem: the pod stayed `Pending` until I created a PVC with exactly that name. Then the claim bound and the pod went `1/1 Running`.

### Takeaways
- Look at where the pod stopped: not scheduled (`Pending`, check the scheduler Events), image problems (`ImagePullBackOff`), crashed (`logs`, exit code), or running but unready (probe and endpoints).
- `describe` says that something failed; `logs` often says why. For OOM, the reason is in the container State instead.
- A fix can expose a second problem, so verify after every fix.
