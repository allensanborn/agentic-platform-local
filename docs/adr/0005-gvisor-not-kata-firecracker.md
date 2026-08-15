# ADR 0005 — gVisor, not Kata + Firecracker

**Status:** accepted
**Date:** 2026-08-15

## Decision

Run lab 5's sandboxes under **gVisor** (`RuntimeClass` named `gvisor`, handler `runsc`)
instead of the workshop's **Kata Containers + Firecracker** (`RuntimeClass` named `kata-fc`).

## Why

Firecracker is a virtual machine monitor. It needs `/dev/kvm`. This node does not have it —
verified, not assumed:

```
$ docker exec k3d-agentic-agent-0 ls /dev/kvm
ls: /dev/kvm: No such file or directory
```

That is not a configuration gap that better flags would close. Both plausible host targets
are architecturally excluded: Windows/WSL2 runs under Hyper-V, which does not expose nested
non-Hyper-V hypervisors, and Apple Silicon has no KVM at all. There is no version of this
repo that runs Firecracker on a consumer laptop.

## What the substitution costs, precisely

RuntimeClass is the seam containerd exposes for exactly this, so the swap is one field on
one manifest. Everything downstream of it is byte-identical to the workshop: the
SandboxTemplate, the WarmPool, the air-gap NetworkPolicy, `automountServiceAccountToken:
false`, the single-use claim lifecycle, and the whole data-in-as-a-file discipline.

**What is preserved:** an isolation boundary with its own kernel, and the workshop's own way
of proving it. The sandbox reports a different kernel from the node it runs on:

```
$ kubectl exec -n agent-sandbox <sandbox-pod> -- uname -r
4.19.0-gvisor
$ docker exec k3d-agentic-agent-0 uname -r
7.0.14-orbstack-00380-ga7e0a2dc9535
```

The system-call surface the untrusted code can reach is the sandbox's, not the host's. For
this lab's actual threat — LLM-written pandas doing something the author did not intend —
that boundary does the same job.

**What is lost, and it is not a detail.** gVisor's kernel is a Go program in userspace.
Firecracker's is a hardware-virtualized VM behind VT-x/AMD-V/EL2. The workshop's claim is
that *"a process that escapes the container escapes into a VM, not onto the node."* Under
gVisor that sentence is false. The chain of custody differs:

| | Kata + Firecracker | gVisor |
|---|---|---|
| Guest kernel | real Linux, in a VM | `runsc`, a Go reimplementation in userspace |
| Enforcement | CPU virtualization extensions | ptrace/KVM-less syscall interception + seccomp |
| An LPE in the guest kernel gets you | ring 0 of a VM; you still face the VMM | ring 0 of nothing; you are still a `runsc` process |
| A bug in the isolation layer itself gets you | a Firecracker VMM escape (very small attack surface, ~50k LOC, jailer-confined) | a `runsc` escape onto the **host kernel** |
| Attack surface presented to hostile code | ~40 hypercalls / virtio devices | the Linux syscall ABI, reimplemented |

So: gVisor narrows the host syscall surface a great deal, but a sufficiently good bug in
`runsc` lands the attacker on the node's kernel directly. Firecracker would require two
independent escapes. This build is a demonstration of the *architecture* of sandboxed
execution; it is not a claim of equivalent assurance, and it should not be cited as one.

## Consequences

- `platform/sandbox/runtimeclass-gvisor.yaml` pins the RuntimeClass to the agent node via
  `scheduling.nodeSelector`, because `scripts/install-gvisor.sh` installs `runsc` only there.
  Without the pin, a sandbox scheduled onto the server node fails to start with a confusing
  containerd error rather than an unschedulable pod.
- k3d nodes are containers, so `runsc` does not survive `k3d cluster delete`. Re-run
  `make gvisor` after any cluster recreate.
- `make sandbox-verify` is the standing check that the boundary is real, not just declared.
- gVisor publishes its arm64 artifacts under `aarch64`; the `arm64` path 404s.
