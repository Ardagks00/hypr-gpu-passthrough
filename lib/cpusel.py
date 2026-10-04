#!/usr/bin/env python3
"""Pick the CPU cores for the VM and print shell assignments.

Rules (same as the setup this project grew out of):
  * Hybrid Intel CPUs: the VM gets P-cores only, the host keeps two P-cores and all E-cores,
    and QEMU's emulator threads run on the E-cores.
  * Other CPUs: the VM gets all cores but two; the emulator runs on the host cores.
  * The core that holds CPU 0 always stays with the host (it handles most interrupts).
  * Among the candidates, the fastest cores (Intel "preferred cores") are taken first.

Usage: cpusel.py [VM_CORES]     (0 or missing = automatic)
"""
import glob
import os
import sys

SYS = "/sys/devices/system/cpu"


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def parse_list(text):
    cpus = []
    for part in filter(None, text.split(",")):
        if "-" in part:
            lo, hi = part.split("-")
            cpus.extend(range(int(lo), int(hi) + 1))
        else:
            cpus.append(int(part))
    return cpus


def ranges(cpus):
    cpus = sorted(set(cpus))
    out, start = [], None
    for i, c in enumerate(cpus):
        if start is None:
            start = c
        if i == len(cpus) - 1 or cpus[i + 1] != c + 1:
            out.append(str(start) if start == c else f"{start}-{c}")
            start = None
    return ",".join(out)


def main():
    wanted = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
    online = parse_list(read(f"{SYS}/online", "0"))
    cores = {}
    for cpu in online:
        topo = f"{SYS}/cpu{cpu}/topology"
        key = (int(read(f"{topo}/physical_package_id", "0")), int(read(f"{topo}/core_id", str(cpu))))
        cores.setdefault(key, []).append(cpu)
    freq = {k: max(int(read(f"{SYS}/cpu{c}/cpufreq/cpuinfo_max_freq", "0")) for c in v)
            for k, v in cores.items()}
    ecpus = set(parse_list(read("/sys/devices/cpu_atom/cpus")))
    hybrid = bool(ecpus)
    pcores = [k for k, v in cores.items() if not set(v) & ecpus]
    ecores = [k for k, v in cores.items() if set(v) & ecpus]
    core0 = next(k for k, v in cores.items() if 0 in v)

    if wanted:
        n_vm = wanted
    elif hybrid:
        n_vm = len(pcores) - 2
    else:
        n_vm = len(cores) - 2
    candidates = [k for k in pcores if k != core0]
    n_vm = max(1, min(n_vm, len(candidates)))
    if n_vm < 2:
        print("CPU_ERROR='Not enough CPU cores: the VM needs at least 2 cores while the host keeps 2.'")
        return
    candidates.sort(key=lambda k: (-freq[k], -min(cores[k])))
    vm = sorted(candidates[:n_vm], key=lambda k: min(cores[k]))
    pin = [c for k in vm for c in sorted(cores[k])]
    threads = min(len(cores[k]) for k in vm)
    if any(len(cores[k]) != threads for k in vm):
        pin = [min(cores[k]) for k in vm]
        threads = 1
    host = [c for c in online if c not in pin]
    emulator = sorted(c for k in ecores for c in cores[k]) if hybrid else host

    print(f"CPU_HYBRID={int(hybrid)}")
    print(f"VM_CORES={len(vm)}")
    print(f"VM_THREADS={threads}")
    print(f"VM_VCPUS={len(pin)}")
    print(f"VCPU_PIN='{' '.join(map(str, pin))}'")
    print(f"VM_CPUS={ranges(pin)}")
    print(f"HOST_CPUS={ranges(host)}")
    print(f"EMULATOR_CPUS={ranges(emulator)}")
    print(f"CPU_TOTAL_CORES={len(cores)}")
    print(f"CPU_PCORES={len(pcores)}")
    print(f"CPU_ECORES={len(ecores)}")


if __name__ == "__main__":
    main()
