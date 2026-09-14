# BruhMount Changelog

### v2.1.0-enhanced (Latest)
* **Manager In-App Updates**: Added `updateJson` metadata and continuous update pipeline for SukiSU, KernelSU, and APatch managers.
* **Module Description Reliability**: Aligned runtime description updates in `metamount.sh` so module feature information is preserved across boots.
* **Milestone Releases**: Added automated GitHub milestone checkpoints compiling all commits and changes since previous builds.
* **Automated Telegram Delivery**: Automatic flashable module packaging with clean monospace change summaries sent to [@bruhperidot](https://t.me/bruhperidot).
* **Upstream Synchronization**: Automated tracking and conflict-free harmonization with upstream NoMount kernel and userspace improvements.

### Milestone 2: Modern WebUI & Diagnostics
* **HyperOS 4 Interface**: Rebuilt WebUI with iOS-style floating pill navbar, smooth tab transitions, and segmented theme controls.
* **Dynamic Theming**: Added dynamic Monet accent palette generation and true OLED/AMOLED pure black theme.
* **SUSFS Diagnostics**: Real-time status cards for SUSFS kernel support, detection state, active path protections, and boot log viewer.
* **Device Identification**: Multi-tier device detection resolving Android version, architecture, and exact device model.

### Milestone 1: Unified Architecture & SUSFS Integration
* **NoMount VFS Redirection**: Direct in-memory VFS interception through the Linux Keyring subsystem (`SYS_add_key`), eliminating mount table entries.
* **Zero Mount Namespace Footprint**: Complete absence of mount points in `/proc/mounts` and `/proc/self/mountinfo`.
* **Automated SUSFS Protection**: Built-in `ksu_susfs` integration cloaking `/data/adb`, active module directories, and library maps on boot.
* **AVC Denial Spoofing**: Automatic kernel-level AVC audit denial spoofing redirected to `priv_app`.
* **Per-App UID Isolation**: Per-application isolation allowing specified apps to bypass module redirection and access pristine stock partitions.
