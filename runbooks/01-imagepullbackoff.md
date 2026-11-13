# ImagePullBackOff (bad image tag)

**Symptom:** `web-badimage` pod never becomes Ready (`0/1`). STATUS shows `ErrImagePull`, then settles into `ImagePullBackOff` as the kubelet backs off between retries.

## Diagnose
```
$ kubectl apply -f scenarios/01-imagepullbackoff.yaml
deployment.apps/web-badimage created

$ kubectl -n lab get pods
NAME                            READY   STATUS         RESTARTS   AGE
web-badimage-78754b95d6-j649v   0/1     ErrImagePull   0          14s
```
The pod is scheduled (not Pending) but the container never starts, so the problem is between "scheduled" and "container created". That points at the image, not at resources or volumes.

```
$ kubectl -n lab describe pod -l app=web-badimage
...
Image:          nginx:1.27-doesnotexist
State:          Waiting
  Reason:       ImagePullBackOff
...
Events:
  Normal   Scheduled  49s  default-scheduler  Successfully assigned lab/web-badimage-... to k8s-lab-control-plane
  Normal   BackOff    20s  kubelet  Back-off pulling image "nginx:1.27-doesnotexist"
  Warning  Failed     9s   kubelet  Failed to pull image "nginx:1.27-doesnotexist": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.27-doesnotexist": ... docker.io/library/nginx:1.27-doesnotexist: not found
  Warning  Failed     9s   kubelet  Error: ErrImagePull
```

`kubectl -n lab get events --sort-by=.lastTimestamp` shows the same sequence: `Pulling` -> `Failed ... not found` -> `ErrImagePull` -> `BackOff` -> `ImagePullBackOff`, repeating with growing gaps.

## Root cause
The registry returned `NotFound` for `docker.io/library/nginx:1.27-doesnotexist`. The tag in the Deployment does not exist. The `code = NotFound ... not found` text is what separates this from other pull failures (see below).

## Fix
Change the image to a tag that exists, e.g. `nginx:1.27-alpine`, and re-apply.

**First attempt did not work.** I replaced the bad tag with `postgres:16-alpine`, copied from the baseline `10-db.yaml` instead of `20-web.yaml`. The pull error went away, but the pod moved to a new failure:
```
$ kubectl -n lab describe pod -l app=web-badimage
    Image:          postgres:16-alpine
    State:          Terminated
      Reason:       Error
      Exit Code:    1
    Restart Count:  4
Events:
  Normal   Pulled   ...  Container image "postgres:16-alpine" already present on machine
  Warning  BackOff  ...  Back-off restarting failed container nginx in pod web-badimage-...
```
The image existed, so the pull succeeded, but it is the database image running in a container named `nginx` on port 80. Postgres started without `POSTGRES_PASSWORD` and exited 1, so the failure changed from ImagePullBackOff to CrashLoopBackOff. Checking the pod after the "fix" is what caught it. The container name and `containerPort` (nginx, 80) identify the right baseline image.

**Correct fix:** set `image: nginx:1.27-alpine` and re-apply.
```
$ kubectl -n lab get pods
web-badimage-75f4ccb888-tffxt   1/1   Running   0   16s

$ kubectl -n lab describe pod -l app=web-badimage
    Image:          nginx:1.27-alpine
    State:          Running
    Ready:          True
    Restart Count:  0
Events:
  Normal  Pulled   Container image "nginx:1.27-alpine" already present on machine ...
  Normal  Started  Container started
```
- [x] Applied the fix and confirmed the pod reaches `1/1 Running`

## How to tell the common pull failures apart
| Message in Events | Likely cause |
|---|---|
| `not found` / `manifest unknown` | Tag or repo name does not exist (this scenario) |
| `unauthorized` / `pull access denied` | Private image, missing or wrong `imagePullSecrets` |
| `toomanyrequests` | Registry rate limit (e.g. Docker Hub anonymous pulls) |
| `i/o timeout` / `no such host` | Node cannot reach the registry (DNS, proxy, firewall) |

## Notes
- During first startup of the baseline, `web` and `db` each logged a transient `Readiness probe failed` event while images were still being pulled and the app warmed up. Both pods went `1/1` on their own, so this is not a fault.
