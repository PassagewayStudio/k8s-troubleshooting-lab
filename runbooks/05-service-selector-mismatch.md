# Service selector mismatch

**Symptom:** The pods are `Running` and `1/1` Ready, but the Service `web-badselector` has no backends, so connections to it fail (refused or timing out).

## Diagnose
Start with the pods, to confirm they are healthy and see their labels:
```
$ kubectl -n lab get pods --show-labels
NAME                   READY   STATUS    RESTARTS      AGE    LABELS
db-fb47694cc-xclx9     1/1     Running   2 (43m ago)   2d4h   app=db,pod-template-hash=fb47694cc
web-6684d45c6f-xbmbw   1/1     Running   2 (43m ago)   2d4h   app=web,pod-template-hash=6684d45c6f
web-6684d45c6f-xdjrf   1/1     Running   2 (43m ago)   2d4h   app=web,pod-template-hash=6684d45c6f
```
Nothing is crashing or unready, so the pods are not the problem. The web pods are labelled `app=web`.

Next, the Service and its selector:
```
$ kubectl -n lab get svc web-badselector -o wide
NAME              TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE     SELECTOR
web-badselector   ClusterIP   10.96.86.162   <none>        80/TCP    2m49s   app=web-app
```
The Service selects `app=web-app`, but the pods are labelled `app=web`.

Then the endpoints, which is the list of pods the Service actually routes to:
```
$ kubectl -n lab get endpoints web-badselector
NAME              ENDPOINTS   AGE
web-badselector   <none>      4m39s

$ kubectl -n lab describe svc web-badselector
Selector:                 app=web-app
Type:                     ClusterIP
IP:                       10.96.86.162
Port:                     <unset>  80/TCP
TargetPort:               80/TCP
Endpoints:
Events:                   <none>
```
`ENDPOINTS` is `<none>` and `Events` is empty. Unlike the other scenarios, there is no error anywhere. Kubernetes does not treat a selector that matches nothing as a fault.

## Root cause
The Service selector `app=web-app` matches no pods, because the pods are labelled `app=web`. A Service only routes to pods whose labels match its selector, so it has zero endpoints and nothing receives traffic, even though the pods are healthy.

## Fix
Change the selector to match the pod labels:
```yaml
selector:
  app: web
```
Re-apply the manifest, then check that `get endpoints web-badselector` lists the web pod IPs on port 80.

Verified:
```
$ kubectl apply -f scenarios/05-service-selector-mismatch.yaml
service/web-badselector configured

$ kubectl -n lab get svc web-badselector -o wide
NAME              TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web-badselector   ClusterIP   10.96.86.162   <none>        80/TCP    10m   app=web

$ kubectl -n lab get endpoints web-badselector
NAME              ENDPOINTS                     AGE
web-badselector   10.244.0.2:80,10.244.0.7:80   12m

$ kubectl -n lab describe svc web-badselector
Selector:                 app=web
Endpoints:                10.244.0.7:80,10.244.0.2:80
```
The selector now matches the two `app=web` pods, and the endpoints list both of them on port 80. The Service kept the same ClusterIP (`10.96.86.162`), and no pods were restarted. The fix was applied to the Service only, and the pods never changed.
- [x] Applied the fix and confirmed the endpoints are populated

## How this differs from scenario 3 (failing readiness probe)
Both end with a Service that has no endpoints, but for different reasons:

| | Scenario 3 (readiness) | Scenario 5 (selector) |
|---|---|---|
| Pod READY | `0/1` | `1/1` |
| Pod `describe` Events | `Readiness probe failed ... 404` | nothing wrong |
| Where the cause is | the pod (probe) | the Service (selector vs labels) |

Rule of thumb: empty endpoints and unready pods, look at the probe. Empty endpoints and healthy pods, compare the Service selector to `--show-labels`.

## Notes
- A typo in the resource name gives a different result: `kubectl get endpoints web-badselctor` returned `Error from server (NotFound)` because no such object exists. `<none>` under ENDPOINTS means the object exists but has no backends. Check the name first when you see NotFound.
- `kubectl get endpoints` prints a deprecation warning on newer clusters. The replacement is `kubectl -n lab get endpointslices -l kubernetes.io/service-name=web-badselector`.
