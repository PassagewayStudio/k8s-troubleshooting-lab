# OOMKilled (memory limit too low)

**Symptom:** `memory-hog` pod restarts over and over. STATUS flips between `OOMKilled`, `CrashLoopBackOff`, and briefly `Running`, and RESTARTS keeps climbing.

## Diagnose
```
$ kubectl -n lab get pods -w
NAME                          READY   STATUS             RESTARTS      AGE
memory-hog-5546d7b646-cc796   0/1     OOMKilled          2 (39s ago)   50s
memory-hog-5546d7b646-cc796   0/1     CrashLoopBackOff   2 (28s ago)   53s
memory-hog-5546d7b646-cc796   1/1     Running            3 (29s ago)   54s
memory-hog-5546d7b646-cc796   0/1     OOMKilled          3 (30s ago)   55s
```
Each cycle the container starts, shows `Running` for about a second, gets killed, then waits out a back-off before the next start. A single `get pods` can show any of these states depending on when you look.

```
$ kubectl -n lab describe pod -l app=memory-hog
    Args:
      --vm
      1
      --vm-bytes
      150M
      --vm-hang
      1
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Ready:          False
    Restart Count:  4
    Limits:
      memory:  50Mi
    Requests:
      memory:     32Mi
QoS Class:                   Burstable
Events:
  Normal   Started    9s (x5 over 99s)   kubelet  Container started
  Warning  BackOff    9s (x5 over 97s)   kubelet  Back-off restarting failed container stress in pod memory-hog-...
```
The cause is in the container's **State / Last State** block (`Reason: OOMKilled`, `Exit Code: 137`), not in the Events, which only say the container started and is backing off. The container args ask the process to allocate `150M` and the memory limit is `50Mi`.

```
$ kubectl -n lab get pod -l app=memory-hog -o jsonpath='{.items[0].spec.containers[0].resources}'
{"limits":{"memory":"50Mi"},"requests":{"memory":"32Mi"}}
```
This confirms the configured limit directly from the live object.

## Root cause
The process tries to hold about 150M of memory, but the container's memory limit is 50Mi. When the container exceeds its limit, the kernel's OOM killer sends SIGKILL, which shows up as `Reason: OOMKilled` and exit code 137 (128 + signal 9). The kubelet then restarts it, it exceeds the limit again, and the pod ends up in a crash loop.

## Fix
Raise the memory limit above the real peak usage, or reduce what the process allocates. Here the allocation is 150M (about 143Mi), so a limit of `200Mi` leaves headroom:
```yaml
resources:
  requests: { memory: 32Mi }
  limits:   { memory: 200Mi }
```
Re-apply the manifest. (Only the limit changed; the request stayed at 32Mi.)

Verified:
```
$ kubectl -n lab get pods
memory-hog-5fc8489588-bzkxl   1/1   Running   0   14s

$ kubectl -n lab describe pod -l app=memory-hog
    State:          Running
    Ready:          True
    Restart Count:  0
    Limits:
      memory:  200Mi
    Requests:
      memory:     32Mi
Events:
  Normal  Started  25s  kubelet  Container started

$ kubectl -n lab get pod -l app=memory-hog -o jsonpath='{.items[0].spec.containers[0].resources}'
{"limits":{"memory":"200Mi"},"requests":{"memory":"32Mi"}}
```
The Deployment rolled out a new pod (`...bzkxl`) with the higher limit. It has run well past the point where the old container was killed (within about a second of starting), with no restarts and no `OOMKilled` in its state.
- [x] Applied the fix and confirmed the pod stays `Running` with no new restarts

Note: requests (32Mi) are well below the actual usage (~143Mi). That is allowed, but it means the scheduler under-reserves memory for this pod. In a real cluster, set the request close to typical usage.

## How this differs from scenario 2 (config crash)
| | Scenario 2 (bad config) | Scenario 4 (OOM) |
|---|---|---|
| Exit code | 1 | 137 |
| Reason in `describe` | `Error` | `OOMKilled` |
| Where the cause is | `kubectl logs` (app error message) | `describe` State/Last State and the memory limit |

## Notes
- Both end in `CrashLoopBackOff`, so the STATUS column alone doesn't tell them apart. The exit code and `Reason` do.
- The image has no tag, so it is treated as `:latest` and the kubelet re-pulls it on every restart (the repeated `Pulling image` events). That's noise here, not the cause.
- In production, `kubectl top pod` (needs metrics-server) or monitoring history helps pick a realistic limit instead of guessing.
