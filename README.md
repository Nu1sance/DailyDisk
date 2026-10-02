<!--
  官网与宣传片尚未上线：下面的 https://dailydisk.app 是预留域名占位。
  上线后全局替换该域名即可（README 中所有官网 / 宣传片链接都指向它）。
-->

<div align="center">

<img src="Config/AppIcon.png" width="148" alt="DailyDisk 图标">

# DailyDisk

**磁盘每天长了多少，都记在哪儿。**<br>
<sub>A daily, privacy-first disk-growth ledger for macOS: which files grew, by how much, and what can't be explained.</sub>

<p>
  <a href="https://github.com/Nu1sance/DailyDisk/actions/workflows/ci.yml"><img src="https://github.com/Nu1sance/DailyDisk/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/APFS-internal%20startup%20disk-3b55d0" alt="APFS">
  <img src="https://img.shields.io/badge/telemetry-none-2ea44f" alt="No telemetry">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p>
  <a href="https://dailydisk.app"><b>🌐 官网</b></a> ·
  <a href="https://dailydisk.app/film"><b>🎬 宣传片</b></a> ·
  <a href="#-快速开始"><b>🚀 快速开始</b></a> ·
  <a href="#-工作原理"><b>🧠 工作原理</b></a> ·
  <a href="#-文档"><b>📚 文档</b></a>
</p>

<sub>官网与宣传片即将上线 · Website &amp; film coming soon</sub>

<br>

<a href="https://dailydisk.app/film">
  <img src="Docs/assets/promo-cover.svg" width="860" alt="观看 DailyDisk 宣传片（即将上线）">
</a>

</div>

<br>

> [!NOTE]
> 第一次完整扫描只是**期初余额**，不会把已有文件当作“新增”。从下一次成功检查开始，DailyDisk 才会给出真正的增长账单。

## ✨ 为什么是 DailyDisk

磁盘分析工具大多回答“**现在**什么占了空间”。DailyDisk 回答的是另一个问题：“**从上次到现在**，空间去了哪儿？”

<table>
<tr>
<td width="50%" valign="top">

### 📈 每日增长账单
每天 05:00 自动做一次完整元数据检查，对比上一份成功报告，列出增长最多的文件与目录，以及释放了空间的位置。

</td>
<td width="50%" valign="top">

### 🧾 带符号的诚实账目
全量扫描与 FSEvents 增量维护有出入时，以 `reconciliationCorrection` 明确记账；APFS 解释不了的部分单列为“未归因”，**绝不编造路径**。

</td>
</tr>
<tr>
<td valign="top">

### 🔐 本机、私密、无遥测
数据只存放在本机私有目录。通知、日志、默认 CLI 输出都不含完整路径；界面中的路径要在当前会话里明确选择后才会显示。

</td>
<td valign="top">

### 🪶 轻量后台，不常驻
后台 helper 按需启动，扫描完成后立即退出。不需要 root、`sudo`、LaunchDaemon，也不会因为失败无限重试。

</td>
</tr>
<tr>
<td valign="top">

### 👀 进度真实可见
显示阶段、计数、耗时和最后更新时间，不伪造百分比。关掉窗口扫描也会继续，重新打开会自动接上进度。原子提交之前都可以安全取消。

</td>
<td valign="top">

### 🧹 自身占用可回收
紧凑库存结构（schema 8 / W6）每天只写入有变化的记录。数据库可在 **设置 → 诊断** 中一键回收空间，不影响基线和历史报告。

</td>
</tr>
</table>

## 🖥 界面一览

| 区域 | 内容 |
| --- | --- |
| **概览** | 最新物理增长、**空间构成卡片**（文件净变化 + 未归因 + DailyDisk 自身开销）、最多 5 项增长与 5 项释放来源，以及最近 14 次检查的增长柱状图 |
| **历史** | 按日期、运行和存储域浏览报告，查看核算、覆盖范围、物理诊断、完整排名和错误；路径显示与 JSON 导出都在工具栏 |
| **设置** | **通用**（每日任务、通知、重新完整检查、本地数据、重置）· **磁盘权限**（完全磁盘访问引导）· **诊断**（验证数据库、数据占用与空间回收、最近运行、复制脱敏诊断） |

界面采用 “Graphite” 风格：中性的系统表面，只用一种靛蓝强调色，同时支持浅色和深色模式。

## 🚀 快速开始

> [!IMPORTANT]
> 需要 **macOS 15+**、内置 APFS 启动盘，以及提供 Swift 6+ 和 macOS 15+ SDK 的 Apple 命令行工具。不需要 Homebrew、Python、Node.js、Docker 或数据库服务器。

**1. 安装开发者工具**（全新的 Mac 需要这一步）

```bash
xcode-select --install
```

**2. 获取源码**

```bash
git clone https://github.com/Nu1sance/DailyDisk.git
cd DailyDisk
```

**3. 构建并安装**，选择下面一种方式：

<table>
<tr><th>🧪 一次性试用（ad-hoc 签名）</th><th>📌 长期使用（固定签名身份，推荐）</th></tr>
<tr>
<td valign="top">

```bash
ALLOW_ADHOC_SIGNING=1 \
  Scripts/build-app.sh --install
open ~/Applications/DailyDisk.app
```

重新构建后可能需要重新授予权限。

</td>
<td valign="top">

```bash
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install
open ~/Applications/DailyDisk.app
```

每次更新都要使用**同一个**签名身份、bundle ID 和安装路径。

</td>
</tr>
</table>

**4. 首次设置**：概览页的工具栏始终只给出一个当前应做的主操作。

1. **允许读取磁盘**：在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中添加 `~/Applications/DailyDisk.app`，然后退出并重新打开应用。
2. **启用每日检查**：注册后台 helper。如果 macOS 需要批准，按钮会变成 **允许后台检查**，并打开“登录项与扩展”。
3. **开始首次检查**：建立期初基线。之后可以随时点 **立即检查**。

> [!TIP]
> 想快速验证效果？基线完成后运行 `mkfile 2g ~/Downloads/DailyDisk-Test/growth-test.bin`（先建好目录），再点 **立即检查**，“历史”里应该能看到约 2 GB 的增长归到这个路径。测试完记得删除。

完整的安装、签名与排障说明见 **[Docs/Installation.md](Docs/Installation.md)**。

## 🧠 工作原理

```mermaid
flowchart LR
    A["⏰ 05:00 / 登录补检<br/>或手动「立即检查」"] --> B["DailyDiskAgent<br/>（无窗口 helper）"]
    B --> C["APFS 拓扑发现<br/>diskutil · DiskArbitration · getfsstat"]
    C --> D["游标 E0<br/>FSEvents 会话"]
    D --> E["全量元数据遍历<br/>/System/Volumes/Data"]
    E --> F["回放扫描期间事件<br/>E0 → E1"]
    F --> G[("SQLite · WAL<br/>只写入变化 + 保留旧值")]
    G --> H["原子提交<br/>库存 + 账目 + 检查点"]
    H --> I["📄 报告<br/>JSON + Markdown"]
    H --> J["🔔 汇总通知<br/>（不含路径）"]
    B -. 进度 / 取消 .- K["DailyDisk.app<br/>SwiftUI 界面"]
```

<details>
<summary><b>核算公式</b>：所有差值都是带符号的 <code>Int64</code> 字节数</summary>

```text
reconciledIndexedDelta    = eventAttributedDelta + reconciliationCorrection

physicalUnattributedDelta = physicalUsedDelta
                          - reconciledIndexedDelta
                          - dailyDiskOverheadDelta
```

- **正的校正**：全量扫描发现了事件维护遗漏的已分配空间。
- **负的校正**：增量索引里还记着已经不存在的空间。
- **未归因**：APFS 克隆、共享 extent、快照、元数据、可清除空间、不可读内容以及已删除但仍被打开的文件，都会让逐文件的物理占用无法精确计算。这一部分单独列出，绝不硬塞给某个路径。
- 硬链接按“卷 / 设备 / inode”只归属到一条规范路径，不会重复计算。

详见 [Docs/Accounting.md](Docs/Accounting.md)。
</details>

<details>
<summary><b>扫描边界与可信事件</b></summary>

- 只对当前启动的 Data 卷（`/System/Volumes/Data`）做完整库存；封装的 System 卷和其他 APFS 角色只记录卷级指标。
- 外置、可移除、网络、光盘和磁盘映像卷默认排除。
- 使用 `fstatat` / `openat`（`AT_SYMLINK_NOFOLLOW`、`O_NOFOLLOW`）逐目录遍历，不跟随符号链接，也不跨越嵌套挂载点。
- 事件丢失或回绕、日志 UUID 变化、挂载变化、根目录替换，或无法消歧的 inode 复用，都会触发权威的全量恢复，绝不推进不可信的检查点。
- 不可读的子树会保留上一次的库存，不会被当作“删除”。

详见 [Docs/Architecture.md](Docs/Architecture.md) 和 [Docs/DailyFullScan.md](Docs/DailyFullScan.md)。
</details>

<details>
<summary><b>每日全量与手动检查规则</b></summary>

- 每个本地日在 **05:00** 自动做一次全量检查；当天已有成功发布的全量报告就跳过。
- 当天还没有全量结果时，手动 **立即检查** 会执行全量；之后的手动请求先尝试增量，事件历史不可信时自动回退到全量。
- 判断“当天完成”依据的是提交后的实际完成时间和已发布的报告，不看开始时间。
- 已关机或已注销的 Mac 无法执行用户任务；补检依赖之后的登录或唤醒，不保证一定会被唤醒执行。
</details>

## 🧰 命令行（自动化与专家诊断）

日常操作都可以在应用里完成。`dailydiskctl` 用于自动化、严格只读的检查，以及依赖退出码的脚本：

```bash
CLI="$HOME/Applications/DailyDisk.app/Contents/Helpers/dailydiskctl"

"$CLI" status
"$CLI" history --limit 14
"$CLI" report
"$CLI" verify        # 0 健康 · 2 数据库异常
"$CLI" diagnostics
```

默认不显示路径。需要路径时必须显式同意：

```bash
"$CLI" report --include-paths
"$CLI" report --include-paths --json          # JSON 含可还原路径，必须同时加 --include-paths
"$CLI" report --run <run-uuid> --domain <container-uuid>
```

<details>
<summary>退出码</summary>

| 码 | 含义 |
| --- | --- |
| `0` | 成功 / 校验健康 |
| `2` | 校验发现数据库不健康 |
| `64` | 用法错误 |
| `65` | 数据损坏或无效 |
| `66` | 数据库或报告不存在 |

严格模式下，若写入进程正在运行或 WAL 非空，CLI 会拒绝读取，避免读到过期数据。等 helper 退出后重试即可。
</details>

## 🔒 数据与隐私

```text
~/Library/Application Support/DailyDisk/
├── DailyDisk.sqlite        # 私有库存、账目与报告索引（WAL）
├── Reports/<run-uuid>/     # report.json + report.md（包含详细路径，仅本人可读）
├── Logs/                   # 无路径的运行日志
├── AlertState.json
└── Control/                # 0700：请求 / 进度 / 取消，固定结构，无路径
```

- 没有云端存储，没有遥测。
- 通知只包含汇总字节数；日志使用类型化的公开字段，敏感字符串会做哈希。
- 界面中的路径只在当前会话里明确选择后显示；导出完整 JSON 需要再次确认。

更多内容见 [SECURITY.md](SECURITY.md)。

## 🧹 维护、卸载与重置

- **回收自身占用**：打开 **设置 → 诊断 → 数据占用**，点 **回收数据库空间**，由后台 helper 整理数据库；基线和历史报告会保留。需要约两倍数据库大小再加 1 GB 的可用空间，开始后不可取消。自动压缩有空间阈值和七天冷却期。详见 [Operations](Docs/Operations.md#reclaiming-dailydisk-data-space)。
- **升级**：GUI、helper 和 CLI 必须一起更新（直接重新执行 `Scripts/build-app.sh --install`），然后重新打开应用。迁移 007/008 会保留已有的库存、检查点和历史报告，不需要重置。
- **卸载**：**设置 → 移除每日任务** →（可选）**设置 → 重置历史与基线…** → 退出应用 → 删除 `~/Applications/DailyDisk.app` → 在系统设置中移除“完全磁盘访问权限”和“通知”里残留的条目。

> [!WARNING]
> 删除历史会同时删除基线，之后就无法再解释相对上一次的变化。

## ⚠️ 已知限制

- 完全磁盘访问权限不会绕过 POSIX 权限、ACL、SIP 或签名系统卷。
- FSEvents 是会合并事件的变化日志，不是审计日志。在两次检查之间创建后又删除的文件无法还原，除非它们仍通过打开的文件描述符或快照占用空间。
- “已删除但仍打开”的文件大小只是逻辑上的证据，不一定等于 APFS 中独占的块。
- 快照大小字段是可选的，不会被直接相加。
- 当前以源码形式分发，按本机架构构建。已在 Apple Silicon 上完成端到端验证；Intel 和全新 Mac 的安装尚未完整验证。目前没有公证安装包、通用二进制或自动更新。

## 🛠 开发

```bash
swift format lint --recursive Sources App Tests
swift build
swift test
Scripts/lint-launch-agent.sh
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh
DAILYDISK_DRY_RUN=1 build/DailyDisk.app/Contents/Helpers/DailyDiskAgent   # 期望退出码 0
```

百万行压力测试需要显式开启（也可以通过手动触发的 GitHub 工作流运行）：

```bash
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory
```

<details>
<summary>仓库结构</summary>

```text
App/DailyDisk/          SwiftUI 前台应用
App/DailyDiskAgent/     无窗口的定时 helper
Sources/DailyDiskCore/      模型、核算、策略、协调器
Sources/DailyDiskStore/     SQLite schema、迁移、generation、报告
Sources/DailyDiskPlatform/  APFS、FSEvents、扫描器、launchd、通知
Sources/dailydiskctl/       严格只读 CLI
Tests/                  Core / Store / Platform / App / CLI / 集成 / 性能
Config/  Scripts/  Docs/
```

一个构建好的应用包里有三个各自签名的可执行文件：`Contents/MacOS/DailyDisk`、`Contents/Helpers/DailyDiskAgent`、`Contents/Helpers/dailydiskctl`。
</details>

提交 PR 前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 中必须保持的不变量。

## 📚 文档

| 文档 | 内容 |
| --- | --- |
| [Installation](Docs/Installation.md) | 全新 Mac 的依赖、源码安装、签名与分发限制 |
| [Architecture](Docs/Architecture.md) | 子系统划分与扫描边界设计 |
| [Accounting](Docs/Accounting.md) | 带符号的核算公式 |
| [DailyFullScan](Docs/DailyFullScan.md) | 每日全量与 W6 持久化 |
| [Database](Docs/Database.md) | SQLite generation、overlay、封存与恢复 |
| [Operations](Docs/Operations.md) | 定时流程、维护与排障 |
| [Testing](Docs/Testing.md) | 自动化与人工发布门槛 |

## 📄 许可证

DailyDisk 采用 [MIT License](LICENSE) 发布。

<div align="center">
<sub>为想知道“空间都去哪儿了”的 Mac 用户而做 · <a href="https://dailydisk.app">dailydisk.app</a>（即将上线）</sub>
</div>
