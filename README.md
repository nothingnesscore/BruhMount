# 🛡️ BruhMount

> **Unified VFS Path Redirection & Automated Kernel SUSFS Metamodule**  
> *Zero Mount Table Footprint. Built-in Security Isolation. Pure RAM Redirection.*

[![CI Build](https://github.com/nothingnesscore/BruhMount/actions/workflows/build.yml/badge.svg)](https://github.com/nothingnesscore/BruhMount/actions/workflows/build.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform: Android](https://img.shields.io/badge/Platform-Android%2012--16-green.svg)](https://source.android.com)

---

## 📖 Overview

**BruhMount** is an advanced Android **Metamodule** that unifies two core concepts in modern Android system modification:
1. **NoMount In-Memory VFS Redirection:** Replaces traditional OverlayFS / Magic Mount with dynamic, RAM-based VFS path interception via the Linux Keyring subsystem (`SYS_add_key`). It creates **0 mount points** in `/proc/mounts` and `/proc/self/mountinfo`.
2. **SUSFS Kernel Automation:** Eliminates the need for a separate `susfs4ksu` module by embedding the `ksu_susfs` control tool directly and automatically registering `/data/adb`, active module paths, and security spoofing at boot (compatible with SUSFS v1.5.0, v2.0.0, and v2.3.0+).

With **BruhMount**, your modules (audio mods, fonts, system tweaks, vendor overlays) function transparently, providing clean filesystem redirection and complete mount isolation without modifying underlying partitions.

---

## ✨ Key Features

* 🚀 **Zero Mount Table Footprint:** Traditional magic mount or overlay solutions create visible filesystem mounts that modify mount namespace records. BruhMount operates entirely in kernel RAM caches without adding any mount entries.
* 🔒 **Built-in SUSFS Automation:** When running on a kernel with SUSFS support (such as **BruhKernel** or compatible GKI builds), BruhMount automatically:
  * Registers `/data/adb` and `/data/adb/modules` with `susfs add_sus_path`.
  * Protects active module directories from unprivileged processes (UID ≥ 10000).
  * Automatically applies AVC denial log spoofing and masks module shared libraries (`.so`) from `/proc/self/maps`.
* 🔑 **Zero `/dev` Nodes or IOCTLs:** Metamodule communication with the kernel takes place via the Linux kernel Keyring subsystem (`SYS_add_key` with key type `"nomount"`), leaving no device files to manage.
* 📱 **Intuitive WebUI:** Inspect injected files, hot-load modules dynamically, and review active redirection rules directly from the KernelSU / APatch manager interface.
* 📁 **Partition Overlay Targeting:** Standard metamodule architecture—only modules containing partition file trees (`system`, `vendor`, `product`, etc.) are processed for VFS redirection. Pure script or service modules remain untouched.
* 🛡️ **Per-App UID Isolation:** Isolate specific applications by UID via the WebUI or CLI to bypass redirections, ensuring they interact strictly with the original stock filesystem.

---

## 🏗️ Architecture & How It Works

```
┌────────────────────────────────────────────────────────┐
│                   Android Userspace                    │
│  [Isolated Application]       [Standard App / System]  │
│             │                            │             │
│   (UID checked by BruhMount)             │             │
│   [Normal Path Resolution]     [VFS Interception]      │
│             │                            │             │
└─────────────┼────────────────────────────┼─────────────┘
              ▼                            ▼
┌────────────────────────────────────────────────────────┐
│                   Linux Kernel Layer                   │
│                                                        │
│  ┌────────────────────────┐  ┌──────────────────────┐  │
│  │     NoMount Subsystem  │  │   Kernel SUSFS Engine│  │
│  │  - RAM-cached dentries │  │  - Path & Stat Hiding│  │
│  │  - Keyring IPC         │  │  - Map Inode Cloaking│  │
│  │  - Zero /proc/mounts   │  │  - AVC Denial Spoof  │  │
│  └────────────────────────┘  └──────────────────────┘  │
│                                                        │
└────────────────────────────────────────────────────────┘
```

When an app accesses a redirected system file (e.g., `/vendor/etc/audio_effects.xml`):
1. **UID Validation:** BruhMount inspects the calling UID. If isolated, the original stock file is returned immediately.
2. **RAM-Level Linkage:** For standard applications, the kernel intercepts the directory operation in RAM and transparently maps read, `mmap`, and iteration operations to the module file.
3. **SUSFS Protection:** Root paths and module shared libraries are concealed from unprivileged processes.

---

## 📥 Installation

### Requirements
* **Root Solution:** KernelSU, SukiSU, KernelSU-Next, or APatch (Android 12 – 16).
* **Kernel:** 
  * Compatible GKI kernel (5.10, 5.15, 6.1, 6.6, 6.12) with GKI LKM support, **OR**
  * Custom kernel with built-in NoMount (`CONFIG_NOMOUNT=y`) and SUSFS (such as **BruhKernel**).

### Setup
1. Download the latest `BruhMount-*.zip` from [GitHub Actions](https://github.com/nothingnesscore/BruhMount/actions).
2. Flash the ZIP inside KernelSU / APatch Manager.
3. If you have a separate `susfs4ksu` module installed, **disable or remove it** — BruhMount handles SUSFS automatically.
4. Reboot your device.
5. All your existing modules will now be injected through BruhMount with zero mount pollution.

---

## 🛠️ Command-Line Utilities

BruhMount bundles two utilities:

### 1. `nm` (NoMount VFS Engine)
```bash
nm rule list                # View all currently active file redirections
nm rule add <target> <mod>  # Manually inject a file into a system path
nm rule add --whiteout <p>  # Hide a system file or directory
nm uid add <uid>            # Isolate an app UID from seeing any modifications
nm uid list                 # Show isolated app UIDs
nm clear all                # Clear all active rules and isolation
nm version                  # Print kernel NoMount subsystem version
```

### 2. `ksu_susfs` (SUSFS Control Tool)
```bash
ksu_susfs show              # Display active SUSFS kernel version and features
ksu_susfs add_sus_path <p>  # Add custom path to SUSFS hide list
ksu_susfs add_sus_map <lib> # Mask mmapped shared library from /proc/self/maps
```

---

## 🤝 Credits & Acknowledgments

BruhMount builds upon foundational open-source engineering:

* **[maxsteeel](https://github.com/maxsteeel):** Creator of **[NoMount](https://github.com/maxsteeel/nomount)**, who pioneered the revolutionary in-memory VFS path redirection framework and Keyring IPC.
* **[simonpunk](https://gitlab.com/simonpunk/susfs4ksu):** Creator of **SUSFS**, whose kernel-level hiding primitives form the security core of modern Android root concealment.
* **[tiann](https://github.com/tiann):** Creator of **KernelSU**, reshaping Android root architecture.
* **[Enginex0](https://github.com/Enginex0):** Creator of **ZeroMount**, whose modular VFS ideas inspired this unified approach.

---

## ⚠️ Disclaimer

BruhMount interacts directly with kernel VFS data structures. While tested extensively, low-level modifications carry inherent risk. Use at your own discretion.
