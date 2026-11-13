# Failing readiness probe

**Symptom:** `web-notready` pod is `Running` but `0/1` Ready; requests to its Service fail or hang.

## Diagnose
```
$ ./lab.sh break 3
$ kubectl -n lab get pods
$ kubectl -n lab describe pod -l app=web-notready     # Events: Readiness probe failed
$ kubectl -n lab get endpoints web-notready           # expect no addresses
```
Output from a clean reproduction (about 12 seconds after `kubectl apply`):
```
$ kubectl -n lab get pods
NAME                            READY   STATUS    RESTARTS      AGE
web-notready-648d5fbcfc-6ttjx   0/1     Running   0             12s
```
STATUS is `Running` with 0 restarts, but READY is `0/1`. Nothing crashed, so this is not a CrashLoopBackOff.

```
$ kubectl -n lab describe pod -l app=web-notready
    State:          Running
    Ready:          False
    Restart Count:  0
    Readiness:      http-get http://:80/healthz delay=2s timeout=1s period=5s #success=1 #failure=3
...
Conditions:
  Ready                       False
  ContainersReady             False
Events:
  Normal   Started    41s              kubelet  Container started
  Warning  Unhealthy  1s (x8 over 36s) kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```
The container started cleanly. The only warning is the repeated readiness failure, and the probe line shows the path it checks: `/healthz`.

```
$ kubectl -n lab get endpoints web-notready
NAME           ENDPOINTS   AGE
web-notready               73s
```
The Service exists but has no endpoints, because only Ready pods are added to them.

## Root cause
The readiness probe checks `GET /healthz` on port 80. nginx does not serve that path, so it returns 404 and the probe fails (`statuscode: 404`). The pod is never marked Ready, so Kubernetes keeps it out of the Service's endpoints and no traffic reaches it, even though the container is running fine. The fix below confirms this: changing only the probe path made the pod Ready.

## Fix
Point the probe at a path that exists (`/`), re-apply, confirm `1/1` Ready and endpoints populated.

Verified:
```
$ kubectl -n lab describe pod -l app=web-notready
    State:          Running
    Ready:          True
    Restart Count:  0
    Readiness:      http-get http://:80/ delay=2s timeout=1s period=5s #success=1 #failure=3

$ kubectl -n lab get pods
db-fb47694cc-xclx9              1/1   Running   ...
web-notready-6f857685f9-jbs74   1/1   Running   0   3m7s

$ kubectl -n lab get endpoints web-notready
NAME           ENDPOINTS       AGE
web-notready   10.244.0.9:80   3h33m
```
The rollout started a new pod with the corrected probe. While the new pod was becoming Ready, the old `0/1` pod from the previous ReplicaSet was still listed; it was removed once the new pod was Ready.
- [x] Applied the fix and confirmed `1/1` Ready with the Service endpoint populated

## Notes
- A failing readiness probe does NOT restart the container (that's liveness); it only removes the pod from Service endpoints. This is the key contrast with scenarios 2 and 4.
- `kubectl get endpoints` prints a deprecation warning on newer clusters. The replacement is `kubectl -n lab get endpointslices -l kubernetes.io/service-name=web-notready`.
- Typo to avoid: `kubectl -n describe pod ...` (missing the namespace) fails with "flags cannot be placed before plugin name".
