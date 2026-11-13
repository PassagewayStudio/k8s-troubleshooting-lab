# CrashLoopBackOff (bad configuration)

**Symptom:** `db-badconfig` pod restarts repeatedly. STATUS alternates between `Error` and `CrashLoopBackOff`, and RESTARTS keeps climbing.

## Diagnose
```
$ kubectl -n lab get pods -w
NAME                            READY   STATUS             RESTARTS      AGE
db-badconfig-5f7bd475c8-rmb2q   0/1     Error              4 (95s ago)   2m12s
db-badconfig-5f7bd475c8-rmb2q   0/1     CrashLoopBackOff   4 (67s ago)   2m38s
```
`Error` is the container having just exited non-zero. `CrashLoopBackOff` is the kubelet waiting before the next restart, with the wait growing each time.

```
$ kubectl -n lab describe pod -l app=db-badconfig
...
State:          Terminated
  Reason:       Error
  Exit Code:    1
Last State:     Terminated
  Reason:       Error
  Exit Code:    1
Restart Count:  5
Environment:    <none>
...
Events:
  Normal   Pulled   22s (x6 over 3m13s)  kubelet  Container image "postgres:16-alpine" already present on machine ...
  Normal   Started  22s (x6 over 3m12s)  kubelet  Container started
  Warning  BackOff  21s (x8 over 3m9s)   kubelet  Back-off restarting failed container postgres ...
```
What `describe` tells us: the image pulled fine and the container started, then exited with code 1 each time. Exit code 1 is a generic application error, not `137` (OOMKilled). `Environment: <none>` is already a hint, but the *reason* is not in `describe`.

```
$ kubectl -n lab logs -l app=db-badconfig
Error: Database is uninitialized and superuser password is not specified.
       You must specify POSTGRES_PASSWORD to a non-empty value for the
       superuser. ...
```
`logs --previous` returned the same message (it reads the last terminated container, which is useful when the current one has no output yet).

## Root cause
The Postgres container has no `POSTGRES_PASSWORD` environment variable. On an empty data directory the image refuses to initialize without it, prints the error above, and exits 1. The kubelet keeps restarting it, which produces the crash loop.

## Fix
Add `POSTGRES_PASSWORD` to the container, e.g. from the baseline `db-credentials` Secret:
```yaml
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: POSTGRES_PASSWORD
```
Re-apply the manifest.

Verified:
```
$ kubectl apply -f scenarios/02-crashloopbackoff.yaml
deployment.apps/db-badconfig configured

$ kubectl -n lab logs -l app=db-badconfig
fixing permissions on existing directory /var/lib/postgresql/data ... ok
creating subdirectories ... ok
...
running bootstrap script ... ok
sh: locale: not found
WARNING:  no usable system locales were found      <- harmless on the Alpine image

$ kubectl -n lab describe pod -l app=db-badconfig
...
    State:          Running
    Ready:          True
    Restart Count:  0
    Environment:
      POSTGRES_PASSWORD:  <set to the key 'POSTGRES_PASSWORD' in secret 'db-credentials'>  Optional: false

$ kubectl -n lab get pods
db-badconfig-5b58647745-sxrlg   1/1   Running   0   50s
```
The Deployment rolled out a new pod, which initialised the database and passed readiness. The old crash-looping pod was replaced.
- [x] Applied the fix and confirmed the pod reaches `1/1 Running`

## Lesson
`describe` tells you *that* the container crashed and with what exit code. `logs` (or `logs --previous`) tells you *why*. Exit code 1 plus an application error message points at configuration; exit code 137 points at OOM (scenario 4).
