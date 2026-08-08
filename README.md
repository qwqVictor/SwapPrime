# SwapPrime

在 VirtualMacOniPad（虚拟 macOS）guest 中，**开机自动诱出 swap** 的菜单栏小工具。

修复 [GitHub issue #24](https://github.com/qwqVictor/VirtualMacOniPad/issues/24)（VM 运行约 26 分钟后 framebuffer 冻结）的预防方案：每次登录时主动制造一次内存压力，让内核激活 swap，从此本次开机就有了"逃生阀"，显示路径的 WIRED 内存分配不再会被饿死。

## 背景

guest（macOS 15.6.1，8GB）长时间运行后：

- `free` 掉到 ~90MB
- 压缩器把 ~7GB 内容压成 ~2.8GB 物理页
- 显示路径（WindowServer → IOSurface）需要 WIRED 内存却拿不到 → 每帧分配卡死 → host framebuffer 冻结
- guest 本身还活着（SSH 可用）——是显示路径被**单向饿死**

swap 是逃生阀，但有两个障碍：

1. **swapfile0 只在第一次 swapout 时才被创建**（`vm_swapfile_create_thread` 只在 swapout 路径被唤醒）。正常负载下永远不发生 swapout。
2. **触发条件① `CC > 0.6×(ANC+CC)` 靠正常负载够不到**——真实开发负载下压缩器平台在 ~45%，从不过线（这是负载性的，不是结构性的）。

SwapPrime 在开机时主动制造内存压力，把压缩器推过 60% 线 → 第一次 swapout → swapfile0 创建 → swap 激活为本次开机的永久逃生阀。重启后 swapfile0 不保留（内核开机不扫描已有 swapfile），所以**每次登录都要重新诱出一次**。

## 工作原理

分配大量匿名内存，交错填充并"呼吸"节流：

- **cold**（默认 auto，8GB 上为 7000MB）：每 16KB 页 = 6KB 随机 + 10KB 规律数据，约 **2.5:1 压缩比**（贴近真实应用数据）。被内核压进压缩器，`CC` 增长。
- **hot**（默认 auto，8GB 上为 3500MB）：纯随机，**不可压缩**，锁死物理内存、把 `free` 压到低位。
- 每填一个 chunk 就检测 `sysctl vm.swapusage`；**swap 一激活立即退出**。
- `free` 低于 `--min-free-mb` 时暂停 ~150ms，让 pageout 后台压缩 cold——模拟真实 26 分钟的逐渐累积。

构建过程中 `CC/(ANC+CC)` 会短暂越过 60%（实测已确认），触发第一次 swapout。

注意：`--hot`/`--cold` 合计通常**超过总物理内存**（8GB 机上为 10.5GB）——这是**有意为之**，不是失控。swap==0 的机器上，正是要靠这种超分配把 cold 压进压缩器、推过 60% 线，逼内核创建 swapfile0；压力不足反而永远过不了线。

## 安装

要求：macOS 11+，Xcode 命令行工具（`clang`）。

```sh
cd ~/Projects/SwapPrime
./build_swap_prime.sh               # 构建 SwapPrime.app
SwapPrime.app/Contents/MacOS/SwapPrime --install
```

`build_swap_prime.sh` 只负责构建；安装由**程序自己完成**（`--install`）：复制到 `~/Applications/` → 写入并加载 LaunchAgent（每次登录自动运行，`RunAtLoad` 会立即触发一次建压）。

运行表现：

| 情形 | 状态栏图标 | 行为 |
|---|---|---|
| swap 激活成功 | 🟢 绿勾 | 发通知，~2 秒后退出 |
| 超时未激活（默认 60s） | 🟠 橙三角 | 发通知，6 秒后退出 |
| 启动时 swap 已激活 | 🟢 绿勾 | 立即成功退出，不重复建压 |

日志：`/tmp/swapprime.log`（超时失败时含最终 free / CC / swapouts，便于诊断）。

卸载：

```sh
~/Applications/SwapPrime.app/Contents/MacOS/SwapPrime --uninstall
```

## 用法（手动运行）

```sh
SwapPrime.app/Contents/MacOS/SwapPrime [--timeout SEC] [--hot MB] [--cold MB] [--min-free-mb MB]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--timeout` | 60 | 秒。超过仍未激活 swap 则发通知退出 |
| `--hot` | auto | 不可压缩内存（MB）——锁 free 用。默认 = 物理内存 × 3500/8192 |
| `--cold` | auto | 可压缩内存（MB）——喂压缩器用。默认 = 物理内存 × 7000/8192 |
| `--min-free-mb` | 512 | "呼吸"阈值：free 低于此值就暂停让 pageout 压缩 |

`--hot`/`--cold` 默认按总物理内存（`sysctl hw.memsize`）等比缩放——以 8GB guest 上调出的 3500/7000 为基准，保证不同内存大小的机器都维持同样的压力比例。显式传值会覆盖自动值。

## 验证 / 测试

仓库内的手动工具（编译：`clang -O2 memory_load.c -o memory_load` 等）：

| 工具 | 作用 |
|---|---|
| `memory_load.c` | 合成内存压力（SwapPrime 建压逻辑的原型）。实测单跑即可激活 swap |
| `swap_priming.c` | 老方案：靠不可压缩分配推过 60% 线。SwapPrime 采用后已冗余 |
| `display_load.m` | 持续动画的 CA 窗口，强制 WindowServer 每帧分配 IOSurface——测试显示路径是否还活着 |

推荐验证流程（一次性，可跳过真实 app）：

1. 重启 guest，确认 `sysctl vm.swapusage` 的 total 为 0（swap 未激活）
2. `./build_swap_prime.sh && SwapPrime.app/Contents/MacOS/SwapPrime --install`（或手动跑 SwapPrime）——看日志确认 swap 激活
3. 用 `display_load` 或正常使用，把 free 压到低位，观察画面是否持续渲染
4. 跑满 26 分钟看是否还冻结

判定：**swap 激活后画面持续 → 预防方案有效**；若仍冻结 → 假设证伪，需重新分析。

## 注意

- 这是**预防**方案，不是**救援**：已经冻住的屏幕不会恢复（显示路径是单向陷阱）。
- swap 文件重启后不保留，必须每个 boot 诱出一次（这正是本工具存在的原因）。
- 建压过程（约 1 分钟内）系统会短暂卡顿/抖动，属预期，且被超时限制兜底。
- 本工具不写系统状态、不落盘、退出即无残留；swap 在重启后自动归零。

## 参考

- [issue #24](https://github.com/qwqVictor/VirtualMacOniPad/issues/24)
- 关键内核机制：`vm_compressor_swapout_conditions_met()`（vm_compressor.c）、`vm_swapfile_create_thread`（vm_compressor_backing_store.c）
