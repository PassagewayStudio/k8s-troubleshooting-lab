# Missing PersistentVolumeClaim

**Symptom:** The `db-nopvc` pod is stuck in `Pending` and never starts. It has no node and no IP.

## Diagnose
```
$ kubectl -n lab get pods
NAME                        READY   STATUS    RESTARTS      AGE
db-nopvc-564f765785-ft72v   0/1     Pending   0             53s
```
`Pending` with 0 restarts means the container never ran. This is different from the crash scenarios, so logs won't help yet.

```
$ kubectl -n lab describe pod -l app=db-nopvc
Node:             <none>
Status:           Pending
IP:
Conditions:
  Type           Status
  PodScheduled   False
Volumes:
  data:
    Type:       PersistentVolumeClaim (a reference to a PersistentVolumeClaim in the same namespace)
    ClaimName:  db-data-missing
Events:
  Warning  FailedScheduling  85s  default-scheduler  0/1 nodes are available: persistentvolumeclaim "db-data-missing" not found. not found
```
Three things stand out: `Node: <none>` and `PodScheduled: False` (the scheduler could not place the pod), the volume references the claim `db-data-missing`, and the `FailedScheduling` event says that claim was not found.

```
$ kubectl -n lab get pvc
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
db-data   Bound    pvc-43f2cab0-...                           1Gi        RWO            standard       2d4h
```
The only PVC in the namespace is `db-data` (used by the baseline database). There is no `db-data-missing`.

## Root cause
The Deployment mounts a PersistentVolumeClaim named `db-data-missing`, but no claim with that name exists in the `lab` namespace. The scheduler cannot place a pod whose required volume claim does not exist, so the pod stays `Pending`, with `FailedScheduling` as the only evidence.

## Fix
Create the missing claim, or correct `claimName` to point at a claim that exists. Do not point it at `db-data`: that volume holds the baseline database's data directory, and two Postgres instances should not share it.

The cleaner option is to create a claim with the name the Deployment expects:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data-missing
  namespace: lab
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
```
Apply it, then confirm the pod schedules and starts.

**What I actually did.** I first changed `claimName` to the existing `db-data`. That let the pod schedule, but it then crash-looped:
```
$ kubectl -n lab get pods
db-nopvc-6df77899c4-zlh7b   0/1   Error     6 (3m ago)    5m55s
...
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Volumes:
      data:
        ClaimName:  db-data
```
`db-data` is the volume the baseline `db` already uses for its data directory, so this is the shared-volume mistake described above. I did not capture `kubectl logs` for that pod, so the exact Postgres error is unconfirmed. Next time, run `kubectl -n lab logs <pod>` before moving on.

I then changed `claimName` to a new name, `db-data-new`, which also did not exist yet. The new pod stayed `Pending` until the claim was created:
```
db-nopvc-854487b799-jwkzk   0/1   Pending   0   92s     (ClaimName: db-data-new, PodScheduled: False)
```
Then I created a PVC with exactly that name:
```
$ kubectl apply -f scenarios/06-pvc.yaml
persistentvolumeclaim/db-data-new created

$ kubectl -n lab get pvc
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
db-data       Bound    pvc-43f2cab0-...                           1Gi        RWO            standard       2d4h
db-data-new   Bound    pvc-bf017429-...                           1Gi        RWO            standard       11s

$ kubectl -n lab get pods
db-nopvc-854487b799-jwkzk   1/1   Running   0   8m19s
```
The pod scheduled as soon as a claim with the matching name existed, and the claim bound. The age of 8m19s counts from when the pod was created, including the time it spent Pending.
- [x] Applied the fix and confirmed the pod reaches `1/1 Running` and the PVC is `Bound`

Lesson: `claimName` in the Deployment and `metadata.name` of the PVC must match exactly. Changing the name in the Deployment alone just changes which missing claim the pod waits for.

Cleanup when done: `./lab.sh fix 6` removes the Deployment but not the PVC, so also run `kubectl -n lab delete pvc db-data-new`.

## Notes
- The cause is in the pod's Events (`FailedScheduling`), not in logs. Pending pods have no logs.
- Missing claim vs. unbound claim are different problems. If the PVC exists but is `Pending`, look at `kubectl describe pvc` (nonexistent StorageClass, no capacity, etc.) instead.
- In this cluster the StorageClass is `standard`. In the baseline events, `db-data` showed `waiting for first consumer to be created before binding`, so a new claim may stay `Pending` briefly until a pod that uses it is scheduled. That is normal.
