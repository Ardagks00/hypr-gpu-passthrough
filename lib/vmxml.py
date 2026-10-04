#!/usr/bin/env python3
"""Build and modify the libvirt domain XML of the Windows VM.

  vmxml.py create OUT key=value...        a new VM without GPU passthrough (for installing Windows)
  vmxml.py passthrough IN OUT key=value...  add the NVIDIA GPU, Looking Glass and tuning to a VM

create keys:      name ram_mib cores threads cpu_vendor(intel|amd) disk win_iso virtio_iso
passthrough keys: pass ("0000:01:00.0 0000:01:00.1"; the GPU function first) rom sub_vendor
                  sub_device (decimal) cores threads vcpu_pin ("4 5 6 7") emulator_cpus shmem_mib
                  battery_aml
Empty values switch the feature off (for example rom= when the vBIOS dump is unusable).
"""
import copy
import re
import sys
import xml.etree.ElementTree as ET

QEMU_NS = "http://libvirt.org/schemas/domain/qemu/1.0"
OSINFO_NS = "http://libosinfo.org/xmlns/libvirt/domain/1.0"
ET.register_namespace("qemu", QEMU_NS)
ET.register_namespace("libosinfo", OSINFO_NS)
Q = "{%s}" % QEMU_NS

HYPERV = [  # Hyper-V enlightenments: better Windows performance and timekeeping
    ("relaxed", {}), ("vapic", {}), ("spinlocks", {"retries": "8191"}), ("vpindex", {}),
    ("runtime", {}), ("synic", {}), ("stimer", {}), ("frequencies", {}), ("tlbflush", {}),
    ("ipi", {}),
]


def sub(parent, tag, attrib=None, text=None):
    el = ET.SubElement(parent, tag, attrib or {})
    if text is not None:
        el.text = text
    return el


def args(items):
    out = {}
    for item in items:
        key, sep, value = item.partition("=")
        if not sep:
            sys.exit(f"vmxml.py: expected key=value, got {item!r}")
        out[key] = value
    return out


def need(a, *keys):
    missing = [k for k in keys if k not in a]
    if missing:
        sys.exit("vmxml.py: missing " + ", ".join(missing))


def cdrom(devices, dev, unit, source):
    disk = sub(devices, "disk", {"type": "file", "device": "cdrom"})
    sub(disk, "driver", {"name": "qemu", "type": "raw"})
    if source:
        sub(disk, "source", {"file": source})
    sub(disk, "target", {"dev": dev, "bus": "sata"})
    sub(disk, "readonly")
    sub(disk, "address", {"type": "drive", "controller": "0", "bus": "0", "target": "0", "unit": str(unit)})
    return disk


def create(a):
    need(a, "name", "ram_mib", "cores", "threads", "cpu_vendor", "disk", "win_iso", "virtio_iso")
    dom = ET.Element("domain", {"type": "kvm"})
    sub(dom, "name", text=a["name"])
    meta = sub(dom, "metadata")
    osinfo = sub(meta, "{%s}libosinfo" % OSINFO_NS)
    sub(osinfo, "{%s}os" % OSINFO_NS, {"id": "http://microsoft.com/win/11"})
    sub(dom, "memory", {"unit": "MiB"}, a["ram_mib"])
    sub(dom, "currentMemory", {"unit": "MiB"}, a["ram_mib"])
    vcpus = int(a["cores"]) * int(a["threads"])
    sub(dom, "vcpu", {"placement": "static"}, str(vcpus))

    # UEFI with Secure Boot and Microsoft's keys enrolled: Windows 11 requires Secure Boot and TPM 2.0.
    os_ = sub(dom, "os", {"firmware": "efi"})
    sub(os_, "type", {"arch": "x86_64", "machine": "q35"}, "hvm")
    fw = sub(os_, "firmware")
    sub(fw, "feature", {"enabled": "yes", "name": "enrolled-keys"})
    sub(fw, "feature", {"enabled": "yes", "name": "secure-boot"})
    sub(os_, "bootmenu", {"enable": "yes"})

    feat = sub(dom, "features")
    sub(feat, "acpi")
    sub(feat, "apic")
    hv = sub(feat, "hyperv", {"mode": "custom"})
    for name, extra in HYPERV:
        sub(hv, name, dict(state="on", **extra))
    if a["cpu_vendor"] == "intel":
        sub(hv, "evmcs", {"state": "on"})   # enlightened VMCS exists only on Intel (VMX)
    sub(hv, "avic", {"state": "on"})
    sub(feat, "vmport", {"state": "off"})
    sub(feat, "smm", {"state": "on"})   # required by the Secure Boot firmware

    cpu = sub(dom, "cpu", {"mode": "host-passthrough"})
    sub(cpu, "topology", {"sockets": "1", "dies": "1", "cores": a["cores"], "threads": a["threads"]})
    if a["cpu_vendor"] == "amd":
        sub(cpu, "feature", {"policy": "require", "name": "topoext"})   # SMT topology on AMD

    clock = sub(dom, "clock", {"offset": "localtime"})
    sub(clock, "timer", {"name": "rtc", "tickpolicy": "catchup"})
    sub(clock, "timer", {"name": "pit", "tickpolicy": "delay"})
    sub(clock, "timer", {"name": "hpet", "present": "no"})
    sub(clock, "timer", {"name": "hypervclock", "present": "yes"})
    sub(dom, "on_poweroff", text="destroy")
    sub(dom, "on_reboot", text="restart")
    sub(dom, "on_crash", text="destroy")
    pm = sub(dom, "pm")
    sub(pm, "suspend-to-mem", {"enabled": "no"})
    sub(pm, "suspend-to-disk", {"enabled": "no"})

    dev = sub(dom, "devices")
    disk = sub(dev, "disk", {"type": "file", "device": "disk"})
    sub(disk, "driver", {"name": "qemu", "type": "qcow2", "cache": "none", "discard": "unmap"})
    sub(disk, "source", {"file": a["disk"]})
    sub(disk, "target", {"dev": "vda", "bus": "virtio"})
    sub(disk, "boot", {"order": "2"})
    win = cdrom(dev, "sda", 0, a["win_iso"])
    sub(win, "boot", {"order": "1"})
    cdrom(dev, "sdb", 1, a["virtio_iso"])
    sub(dev, "controller", {"type": "usb", "model": "qemu-xhci", "ports": "15"})
    sub(dev, "controller", {"type": "pci", "model": "pcie-root"})
    # Spare PCIe slots; libvirt adds more when devices need them.
    for _ in range(8):
        sub(dev, "controller", {"type": "pci", "model": "pcie-root-port"})
    nic = sub(dev, "interface", {"type": "network"})
    sub(nic, "source", {"network": "default"})
    sub(nic, "model", {"type": "virtio"})
    sub(dev, "console", {"type": "pty"})
    ch = sub(dev, "channel", {"type": "spicevmc"})
    sub(ch, "target", {"type": "virtio", "name": "com.redhat.spice.0"})
    sub(dev, "input", {"type": "tablet", "bus": "usb"})
    tpm = sub(dev, "tpm", {"model": "tpm-crb"})
    sub(tpm, "backend", {"type": "emulator", "version": "2.0"})
    gr = sub(dev, "graphics", {"type": "spice", "autoport": "yes"})
    sub(gr, "listen", {"type": "address"})
    sub(gr, "image", {"compression": "off"})
    sub(dev, "sound", {"model": "ich9"})
    video = sub(dev, "video")
    sub(video, "model", {"type": "qxl", "heads": "1", "primary": "yes"})
    for _ in range(2):   # USB redirection from the SPICE console (virt-manager)
        sub(dev, "redirdev", {"bus": "usb", "type": "spicevmc"})
    return dom


def pci_addr(bdf):
    m = re.fullmatch(r"([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])", bdf)
    if not m:
        sys.exit(f"vmxml.py: bad PCI address {bdf!r}")
    d, b, s, f = m.groups()
    return {"domain": "0x" + d, "bus": "0x" + b, "slot": "0x" + s, "function": "0x" + f}


def remove_all(parent, path):
    for el in parent.findall(path):
        parent.remove(el)


def insert_after(parent, new, *tags):
    """Insert NEW after the last child with one of TAGS (libvirt's schema wants a fixed order)."""
    idx = -1
    for i, child in enumerate(list(parent)):
        if child.tag in tags:
            idx = i
    if idx < 0:
        parent.insert(0, new)
    else:
        parent.insert(idx + 1, new)


def passthrough(dom, a):
    """Change the definition in place, so running it again (or on a tuned VM) changes only what it must."""
    need(a, "pass", "rom", "sub_vendor", "sub_device", "cores", "threads", "vcpu_pin", "emulator_cpus",
         "shmem_mib", "battery_aml")
    functions = a["pass"].split()
    if not functions:
        sys.exit("vmxml.py: no PCI functions to pass through")
    dev = dom.find("devices")

    # Replace earlier GPU hostdevs (alias ua-gpu*) and reuse their PCIe root port, so the GPU keeps its
    # place in the guest and Windows does not see a new device.
    old_buses, position = set(), None
    for i, hd in enumerate(list(dev)):
        alias = hd.find("alias") if hd.tag == "hostdev" else None
        if alias is not None and alias.get("name", "").startswith("ua-gpu"):
            addr = hd.find("address")
            if addr is not None and addr.get("bus"):
                old_buses.add(int(addr.get("bus"), 16))
            if position is None:
                position = i
            dev.remove(hd)
    used = {int(el.get("bus"), 16) for el in dom.iter("address")   # guest buses still in use
            if el.get("type") == "pci" and el.get("bus")}
    ports = {int(c.get("index")): c for c in dev.findall("controller")
             if c.get("type") == "pci" and c.get("index") is not None}
    free = sorted(i for i in old_buses - used if ports.get(i) is not None and ports[i].get("model") == "pcie-root-port")
    if free:
        port_index = free[0]
    else:
        port_index = max(list(ports) + [0]) + 1
        port = ET.Element("controller", {"type": "pci", "index": str(port_index), "model": "pcie-root-port"})
        insert_after(dev, port, "controller")
    if position is None:
        position = 0
        for i, child in enumerate(list(dev)):
            if child.tag in ("video", "hostdev", "graphics", "input", "channel", "console", "serial",
                             "interface", "controller"):
                position = i + 1
    for n, bdf in enumerate(functions):
        hd = ET.Element("hostdev", {"mode": "subsystem", "type": "pci", "managed": "yes"})
        src = sub(hd, "source")
        sub(src, "address", pci_addr(bdf))
        sub(hd, "alias", {"name": "ua-gpu" if n == 0 else f"ua-gpu-{n}"})
        if n == 0 and a["rom"]:
            sub(hd, "rom", {"file": a["rom"]})
        guest = {"type": "pci", "domain": "0x0000", "bus": "0x%02x" % port_index, "slot": "0x00",
                 "function": "0x%x" % n}
        if n == 0 and len(functions) > 1:
            guest["multifunction"] = "on"   # the GPU and its audio function stay one device, as on the host
        sub(hd, "address", guest)
        dev.insert(position + n, hd)

    # vCPU count and topology follow the detected CPU split (the installer may run on changed settings).
    vcpus = int(a["cores"]) * int(a["threads"])
    dom.find("vcpu").text = str(vcpus)
    topo = dom.find("cpu/topology")
    if topo is not None:
        topo.set("cores", a["cores"])
        topo.set("threads", a["threads"])

    # CPU pinning: vCPUs on their own cores, QEMU's own threads elsewhere.
    pins = a["vcpu_pin"].split()
    if pins and len(pins) != vcpus:
        sys.exit(f"vmxml.py: {vcpus} vCPUs but {len(pins)} pinned CPUs were given")
    tune = dom.find("cputune")
    if tune is None and pins:
        tune = ET.Element("cputune")
        insert_after(dom, tune, "vcpu", "iothreads")
    if tune is not None:
        remove_all(tune, "vcpupin")
        remove_all(tune, "emulatorpin")
        for i, cpu in enumerate(pins):
            tune.insert(i, ET.Element("vcpupin", {"vcpu": str(i), "cpuset": cpu}))
        if pins and a["emulator_cpus"]:
            tune.insert(len(pins), ET.Element("emulatorpin", {"cpuset": a["emulator_cpus"]}))

    # Hide the hypervisor from NVIDIA's driver (older drivers refuse to start in a VM: Code 43).
    feat = dom.find("features")
    hv = feat.find("hyperv")
    if hv is None:
        hv = ET.Element("hyperv", {"mode": "custom"})
        insert_after(feat, hv, "acpi", "apic", "pae", "hap", "privnet")
    vid = hv.find("vendor_id")
    if vid is None:
        vid = ET.Element("vendor_id")
        insert_after(hv, vid, "relaxed", "vapic", "spinlocks", "vpindex", "runtime", "synic", "stimer", "reset")
    vid.set("state", "on")
    vid.set("value", "1234567890ab")
    kvm = feat.find("kvm")
    if kvm is None:
        kvm = ET.Element("kvm")
        insert_after(feat, kvm, "acpi", "apic", "pae", "hap", "privnet", "hyperv")
    hidden = kvm.find("hidden")
    if hidden is None:
        hidden = sub(kvm, "hidden")
    hidden.set("state", "on")

    # Looking Glass reads the guest's frames from this shared memory.
    shm = dev.find("shmem[@name='looking-glass']")
    if shm is None:
        shm = sub(dev, "shmem", {"name": "looking-glass"})
    remove_all(shm, "model")
    remove_all(shm, "size")
    shm.insert(0, ET.Element("model", {"type": "ivshmem-plain"}))
    size = ET.Element("size", {"unit": "M"})
    size.text = a["shmem_mib"]
    shm.insert(1, size)

    # Input goes through Looking Glass; virtio devices replace the USB tablet. A plain VGA adapter stays
    # as a fallback screen (Looking Glass's documentation recommends it over QXL).
    for inp in dev.findall("input"):
        if inp.get("type") == "tablet":
            dev.remove(inp)
    for kind in ("mouse", "keyboard"):
        if not any(i.get("type") == kind and i.get("bus") == "virtio" for i in dev.findall("input")):
            inp = ET.Element("input", {"type": kind, "bus": "virtio"})
            insert_after(dev, inp, "input", "channel", "console", "serial", "interface", "controller")
    for model in dev.findall("video/model"):
        if model.get("type") == "vga" and model.get("vram") == "16384" and not len(model):
            continue
        keep = {k: model.get(k) for k in ("heads", "primary") if model.get(k)}
        model.attrib.clear()
        model.attrib.update({"type": "vga", "vram": "16384", **keep})
        for child in list(model):
            model.remove(child)
    # Memory ballooning cannot work with VFIO (all guest memory is pinned).
    balloon = dev.find("memballoon")
    if balloon is None:
        balloon = sub(dev, "memballoon")
    balloon.attrib.clear()
    balloon.set("model", "none")
    for child in list(balloon):
        balloon.remove(child)

    # Boot from the disk; the Windows installation media is no longer needed.
    for disk in dev.findall("disk"):
        boot = disk.find("boot")
        if disk.get("device") == "disk" and disk.find("target").get("dev") == "vda":
            if boot is None:
                boot = sub(disk, "boot")
            boot.set("order", "1")
        elif disk.get("device") == "cdrom":
            if boot is not None:
                disk.remove(boot)
            if disk.find("target").get("dev") == "sda":
                remove_all(disk, "source")

    # Laptop GPUs: a fake battery (else Code 43) and the real subsystem ID (the driver checks it).
    # Other QEMU arguments and overrides in the definition are kept.
    cmd = dom.find(Q + "commandline")
    if cmd is not None:
        args_ = list(cmd)
        for i, arg in enumerate(args_):
            if arg.get("value") == "-acpitable" and i + 1 < len(args_):
                cmd.remove(arg)
                cmd.remove(args_[i + 1])
    if a["battery_aml"]:
        if cmd is None:
            cmd = ET.SubElement(dom, Q + "commandline")
        sub(cmd, Q + "arg", {"value": "-acpitable"})
        sub(cmd, Q + "arg", {"value": "file=" + a["battery_aml"]})
    if cmd is not None and not len(cmd):
        dom.remove(cmd)
    ov = dom.find(Q + "override")
    if ov is not None:
        for qd in ov.findall(Q + "device"):
            if qd.get("alias") == "ua-gpu":
                ov.remove(qd)
    if int(a["sub_vendor"] or 0) and int(a["sub_device"] or 0):
        if ov is None:
            ov = ET.SubElement(dom, Q + "override")
        qd = sub(ov, Q + "device", {"alias": "ua-gpu"})
        fe = sub(qd, Q + "frontend")
        sub(fe, Q + "property", {"name": "x-pci-sub-vendor-id", "type": "unsigned", "value": a["sub_vendor"]})
        sub(fe, Q + "property", {"name": "x-pci-sub-device-id", "type": "unsigned", "value": a["sub_device"]})
    if ov is not None and not len(ov):
        dom.remove(ov)
    return dom


def write(dom, path):
    ET.indent(dom, space="  ")
    ET.ElementTree(dom).write(path, encoding="unicode", xml_declaration=False)
    with open(path, "a") as f:
        f.write("\n")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("create", "passthrough"):
        print(__doc__.strip())
        return 2
    if sys.argv[1] == "create":
        write(create(args(sys.argv[3:])), sys.argv[2])
    else:
        if len(sys.argv) < 4:
            print(__doc__.strip())
            return 2
        dom = ET.parse(sys.argv[2]).getroot()
        write(passthrough(dom, args(sys.argv[4:])), sys.argv[3])
    return 0


if __name__ == "__main__":
    sys.exit(main())
