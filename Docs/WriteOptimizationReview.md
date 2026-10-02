# 每日全量写入审查与后续规划（2026-10-02）

最初审查针对 schema 7 的生产写入链路；随后主线提交低风险 no-op 防护，并在本地 W6 分支接入 schema 8 差异持久化。本文区分原始观测、计划和分支验证；已安装应用仍为 schema 7。优先降低累计写入，其次控制长期占用，不能把 DB 变小等同于 SSD 写入变少。

## 证据与测量边界

10 月 2 日例行任务 05:00:05–05:20:15 成功，直接 dailyFull，无事件溢出。helperStarted 到 helperFinished 的 Darwin 进程写入计数差为 16,388,493,312 字节，约 16.39 GB。它不是读取与写入之和，也不是 NAND 写入；子进程、进程退出之后的写回与其他进程不保证计入。阶段缓冲归属可能延后，以下是观测边界差，而非逐 SQL 精确归因。

| 阶段 | 写入约数 | 代码路径 |
| --- | ---: | --- |
| 遍历入库 | 11.628 GB | FileInventoryScanner → InventoryStore.append → HybridInventoryWriter |
| opaque 保留及事件补偿 | 0.017 GB | preserveOpaqueSubtrees / InventoryMutator |
| sealing | 1.694 GB | finalizeCanonicalAttributionObserved |
| 库存差分 | 0.001 GB | deriveSnapshotChanges |
| 提交 | 1.024 GB | validateLedger / applyMutations / applyCanonicalAttributions / write(changes:) |
| 报告与通知边界 | <0.001 GB | commitReport / notification |
| 最后保留期清理 | 2.022 GB | pruneRetiredGenerations 及 helper retention |

当前 DB 文件 5,239,717,888 字节，空闲页 2,294,747,136 字节（43.8%），WAL 为零；库存一代 active、一代 retired，无 staging/overlay 遗留。此前只读 dbstat 显示 hybrid_order 约 693.14 MB，其反向唯一索引约 680.75 MB；change_ledger 表约 297.48 MB。这些是**现存占用**，不是今天新增或对应阶段的写入量。

今天 59,948 条变化明细含 37,019,443 字节 JSON 和 7,449,905 字节独立前后路径字段，未计行/索引/页面开销。报告的 184,639,488 字节自身增量采在提交之前，不能归因成“今天提交的这些明细”。没有昨日同阶段逐表、WAL、空闲页快照，无法精确拆分该增量。

## 已落地，不能重复算作新优化

- 每日全量从当前 journal 建立 E0，只回放扫描期间事件，不再维护跨日 expected-active 事件视图；同日后续手动请求仍可增量。
- 1024 条批次、64 MiB writer cache、32 MiB soft / 128 MiB hard 的事务间 WAL 管理，保留 synchronous=FULL；单事务允许超过阈值。
- schema 6 整数 generation/volume 键、共享 parent/name 节点、按代排序表。
- 最新 retired 库存保留 24 小时；空间回收与压缩分开，自动 VACUUM 仍有 >1 GB / >25% / 七天条件。
- 进度限频、诊断轮转、候选身份增量清理和 bounded paging。

原 10 万行夹具的 37.6% 优化收益不能直接外推此次实机 16.39 GB。真实文件数量、路径宽度、inode 顺序和索引工作集不同。

## 写入链路发现

### A. 每日重新写入全代记录，且同批要维护多个 B-tree（已确认）

InventoryStore.append 每批启动事务，创建批次级 HybridInventoryWriter；每条记录 upsert hybrid_objects、hybrid_paths、hybrid_order，同时维护 UNIQUE 和外键查询索引。节点字典共享并不意味着对象和路径代次记录共享。目录遍历按有限目录块排序，不能假定整个输入按 inode 或各表主键顺序排序。

**待验证假设：**不同索引的写入局部性差、工作集超出 cache、频繁 checkpoint/页溢写，使有限批次重复弄脏相同页面。没有页级计数，不能宣称这已解释全部 11.63 GB。

先实验：固定 1024 批次，仅比较 cache/checkpoint 配置；再单独比较批次内按对象键/路径键分别组织写入。小范围排序不能假装成全量排序，额外排序临时文件也必须计入。1024 已是 InventoryRecordBatch.maximumRecordCount 的当前上限；扩大批次前核对 InventoryRecordBatch 上限和取消延迟，不直接改成巨型事务。

硬链接/重复事件可能产生值完全相同的 upsert。可以实验带 NULL-safe 值比较的更新条件，但新 generation 的绝大多数行仍是 INSERT，因此收益预计局限于重复身份和补偿，不承诺全局大幅下降。必须保持 write() 返回值、coverage 计数和修订失效语义。

### B. 全量 canonical 中间表仍保存 UUID 和完整路径（已确认，优先结构实验）

finalizeCanonicalAttributionObserved 将全量规范归属写到 run_canonical_attributions；其记录包含 run/target/volume 标识和完整 path。该表是 main 数据库中的运行暂存表，**不是 SQLite TEMP 表**，会产生 WAL。提交时 applyCanonicalAttributions 再通过 hybrid_order 将完整路径转为 path_id 写入 hybrid_canonical，最后清理运行暂存记录。

候选一：为全量 staging 单独使用整数键/path_id 的 compact canonical 暂存表示。候选二：在 inactive staging 内一次生成最终 canonical，封存后提交只验证并激活，避免整代再拷贝。第二种改动更大；事件 overlay 应先一致地合并或有等价解析，不能让尚未应用的 mutation 与 canonical 脱节。取消/修改必须使 seal 失效，增量候选路径不得退化成全代重建。

不要为了少写一张表而删除 semantic ledger 验证、完整排序等价检查、硬链接规范归属或原子激活。收益需覆盖 sealing + commit + cleanup 的总和，防止只是把写入移到另一阶段。

### C. hybrid_order 的反向唯一索引携带长路径（已确认，后续 schema 原型）

当前 WITHOUT ROWID 表主键为 (generation_id,path)，另有 UNIQUE(generation_id,path_id)。同结构内存实验的 PRAGMA index_xinfo 明确显示：反向唯一索引除 generation_id/path_id 外还含 path（key=0 的辅助列）。这符合 [SQLite 文件格式说明](https://www.sqlite.org/fileformat.html#suppression_of_redundant_columns_in_without_rowid_secondary_indexes)：二级索引需要携带对应主键字段。

因此“父节点 + 文件名”没有消除排序结构里的完整路径存储，且长路径参与两棵 B-tree。但不能直接删除 UNIQUE：它支持反查与排序等价检查；也不能直接交换主键，可能只是把重复移动到另一个索引。

实验对比当前布局、窄整数 rowid 的排序记录 + 两个唯一索引、跨代共享不可变原始路径排序字典。比较总页面/累计写入/分页 VM steps，不只比较某个索引。必须保留原始字节顺序、非 UTF-8、子树范围 seek、同节点唯一性、FK 和历史代隔离。更改需新增迁移，不能修改已发布 006/007。

### D. 旧代清理本身有明显写入（阶段观测确认，细项尚未分解）

清理阶段约写 2.02 GB；generation cleanup trigger 删除 canonical、paths、objects，路径删除又涉及 ordering 外键级联与多个索引。保留旧代本身不是每天写入的唯一原因，删除它也会弄脏页面。

在合成夹具分开记录各删除步骤、外键级联和节点 GC 的写入。不要删除 FK、恢复窗口或 active/checkpoint 引用保护；不能把拆成小批删除自动视为低写入，小批也可能增加重复页写回。优先减少被重复维护的记录/索引数量，批量与排序方案需比较整体写入和中断恢复。

### E. ledger 重复保存结构字段和完整 JSON，长期不淘汰（已确认）

write(changes:) 同时保存类型/来源/路径/delta 等列，以及 encoder.encode(change) 完整 JSON。历史表没有按年龄删除机制，外部 Reports 的 400 天保留期不等于数据库 ledger 的保留期。

先核对哪些列确实用于查询/完整性验证，再实验单一规范表示或紧凑 payload；不能直接删列/JSON，报告恢复和验证依赖它们。为老明细设计保留/汇总契约，保留日报摘要和必要核验依据，再分批安全淘汰。该项主要控制长期增长；当日新 ledger 远小于遍历写入，不能把它作为解决 11.63 GB 的首要方案。

### F. 临时排序/验证与外围写入（待量化）

当前 temp_store=FILE、temp cache 8 MiB；ledger_validation_balance 为 semantic 验证临时表，canonical 排序也可能产生临时 I/O。先采集 SQLite cache miss/write/spill、sort 与临时文件汇总，不直接切换无上限内存。维持有界内存、取消及低内存失败安全。

父节点缓存目前随批次销毁；跨批缓存可能减少查询/CPU，但不能默认它降低写入，且回滚后必须丢弃新插入 ID。进度/日志已限频，从今天阶段数据看不是首要目标。去掉重复 DELETE 调用之类微优化要先确认实际有行可删，不能把空表 DELETE 估算成整表写入。

## 原分阶段候选（优先级由下文 W6 主方案替代）

1. **W1：补测而不改变算法。** 在 synthetic fixture 添加事务/页缓存/checkpoint/spill 的有界汇总；相同阶段记录 DB/WAL 分配、freelist、表/索引占用。实机只在自然例行窗口采样，不再额外全盘扫描。完整 dbstat 只用于显式诊断或合成测试，不能放进 GUI 轮询。配对保留 APFS 和自身采样，另加清理后“当前占用”，不混用报表时间边界。
2. **W2：无 schema 变更的 A/B。** 固定数据与 FULL 配置，单因素比较 cache/checkpoint、批内写入顺序和 no-op upsert。候选 64/128 MiB cache、32/64 MiB soft checkpoint 仅为实验参数；限制内存和事务间 WAL，记录大事务峰值。不得通过额外 VACUUM、关闭持久性或跳过审计换收益。
3. **W3：compact canonical 原型。** 优先测量消除完整路径 canonical 中间表示及重复复制的收益；验证全量与同日增量、seal 失效、opaque/硬链接及 crash recovery。只有收益成立才设计新迁移。
4. **W4：排序索引布局 + 旧代删除实验。** 分开验证 C/D，不同时重写全部存储引擎。保留子树范围扫描性能和原始字节语义。
5. **W5：历史明细保留/编码。** 独立解决长期容量边界，明确旧报告再生成、验证和原始明细可用期限；不擅自删除已保存历史。
6. **W6：必要时才做跨代未变化记录复用。** 每天完整 stat，但仅写变化与新的代次引用。必须有可靠删除发现、回滚及旧代隔离；不要为避免写入而漏扫文件。该方案风险高于前三项，后置。

用固定种子合成真实复杂度：百万规模、深/长/非 UTF-8 路径、打乱 inode 顺序、硬链接、opaque、零变化/约 3% 变化/大量删除、三轮替换及到期清理。不导出真实路径构造夹具。每次只改一个变量，小规模筛选后百万规模确认，避免无意义反复写盘。

验收要同时报告完整任务累计写入、阶段写入、耗时、RSS、WAL 峰值、最终占用与空闲页；区分一次性迁移成本、稳态成本及压缩成本。重复控制组确认噪声范围，不以单次微小下降宣布收益。保持 accounting、E0/E1、opaque、硬链接、writer lease、原子提交和报告恢复回归；慢读者、磁盘不足、强杀未提交事务必须保守失败。不得承诺预定节省比例或 SSD 寿命百分比。

## 本轮结果

已完成源码链路审查，并用合成内存结构确认反向排序索引携带完整路径。实机阶段计数及占用来自本次会话前面的只读检查；本轮没有再次触发真实扫描、压缩或百万行写入试验。结论是候选优化与可复现实验计划，不是新优化已落地。schema 7 的生产数据结构与 FULL 持久性保持不变。

基础检查：格式、构建、LaunchAgent lint、git diff --check 通过；默认并发测试 275 项通过（6.739 秒，4 个 opt-in 未启用）。这些检查确认当前基线未被文档审查破坏，不代表上述候选优化已实现或有节省收益。


## 决策更新：W6 为主方案（2026-10-02）

用户选择以最大限度降低累计写入为目标，同时要求保持性能；实现工作量不作为后置理由。主线改为 **每日完整读取元数据、仅持久化变化**。当前 schema 7 全代重建仍是生产基线，W6 在独立本地分支实现和验收，不提前宣称完成或替换已安装应用。

目标结构是一份当前库存、本轮差异暂存，以及恢复窗口内的旧值/删除记录。未变化的对象、路径、排序索引和 canonical 共同复用；不得每天为所有对象新增代次成员行或更新 last_seen_run，否则仍是全量写入。初次基线没有可复用数据，允许完整构建。高变化负载也不能承诺低写入。

执行流程与边界：

1. 从当前 journal 建立可信 E0，冻结本轮逻辑基线；仍完整 stat，不依赖昨天 journal 或目录 mtime 跳过文件。
2. 按目录批量预取旧记录并比较；有界缓存、原始字节键、巨型目录分页，避免每个文件多次随机查询。对象不同路径的观察保留原始覆盖顺序，不能用不稳定排序改变结果。
3. 使用精确内存访问标记或目录级归并发现删除；不逐条持久化“已见过”。位图以有界稠密编号或分段结构实现，不能按稀疏最大 inode/ID 分配。路径和对象的已见状态必须分离，硬链接少一个路径不等于对象删除。无法读取的子树继承历史；取消/崩溃丢弃未提交工作即可重新扫描。
4. 仅暂存新增、修改、删除；E0–E1 回放在同一逻辑视图上应用，重复事件不得重复记账。节点替换、inode 复用、opaque、挂载/UUID 变化保持保守处理。
5. canonical 只重算受影响对象；路径字典和排序结构跨轮复用。目录改名必须覆盖后代实际路径变更。完整审计可以读全量，不能为审计重写全量。
6. 封存并验证差异；变化应用、旧值保留、checkpoint、ledger、samples 和成功状态原子提交。取消仅在提交前。SQLite 的长读事务/WAL 不是跨日历史存储方案，不能用它长期固定旧版本。
7. 24 小时恢复窗口保存变更前旧值和必要版本关系，未变化数据共享；回收仅删除已过期且无引用的版本。报告恢复必须先于新工作，历史日报保留；不擅自删除旧历史或重置本机。

落地顺序：W1 精确测量 → W6 存储/差异算法原型与正确性测试 → 吸收 W3/W4 的紧凑 canonical/路径布局 → 接入完整扫描、事件、提交和恢复 → 性能与故障验收 → 新迁移和生产切换。W2 仅做独立、低风险且有证据的小改动；W5 是长期容量工作，不阻塞 W6。迁移必须保留当前 schema 7 库存/历史；早前内测删除旧库授权不自动沿用。

W1 计量需区分 CACHE_WRITE（WAL 模式下的 WAL 页写）、CACHE_SPILL（事务中溢写）、checkpoint 数据库回写与临时 I/O，不重复相加。支持性检查以系统 SQLite 返回值为准。缓存增大不消除每批 COMMIT 的 WAL 写入；checkpoint 延后单独测量。保持 FULL，记录 reader pinning 与事务外守卫，禁止无上限缓存/WAL。

验收矩阵：相同种子和原始字节数据，对照当前 schema 7，在零变化、约 3% 变化、大量增删、目录改名、硬链接、inode 复用、非 UTF-8、opaque 和高变化负载下比较最终库存、canonical、signed ledger、checkpoint 与报告。额外验证跨批重复观察、取消、进程强杀、提交失败、磁盘不足、报告恢复、版本回收和读者阻塞。先小规模筛选，百万规模确认；累计写入、阶段写入、RSS、WAL/临时文件峰值和总耗时都需报告。变化少不等于按相同比例降低页写入，不承诺节省比例。实机只采下一次自然到期任务。

### 主线低风险改动

重复写同一对象时，仅当 kind、大小、链接数或可空时间字段变化才 UPDATE；相同路径排序映射不再重复 UPDATE。保留 membership 写入及返回值语义、seal 失效、写入顺序和错误时缓存清理。排序映射不一致仍通过原有 NOT NULL 约束拒绝，不用 DO NOTHING 隐藏损坏。此项不改变 schema，预期收益仅限重复身份/补偿，不代表解决全代重写。新增更新触发器审计回归验证真实跳过与变更仍生效。


## W6 分支落地与测量（2026-10-02）

主线 `92509b6` 已推送；`feature/w6-delta-inventory` 只保留在本地。W6 已接入生产 `SQLiteInventoryStore` 和 daily-full coordinator，不再仅是独立实验。Migration 008 保留 schema 7 数据，新增变化前旧值及版本链；首次基线/legacy recovery 仍可建立完整 generation。没有替换已安装应用、重置库存或触发真实扫描。

已落地：1,024 条扫描批次、256 路径预取、精确分段 seen 位图、opaque 继承、删除分页、E0–E1 overlay、候选 canonical、原子差异/旧值/checkpoint 提交、24 小时已发布版本前缀回收。对象元数据与路径独立持久化：只有大小/时间变化时不写路径、排序或当前 canonical。正常增量提交也保留旧值，避免破坏已有恢复链。短期版本是逻辑基线，不复制整代，也不提供 GUI 历史回滚。

性能测试发现并修复了两个问题：逐条查询准备开销改为批量预取；高变化 canonical 查询原本按 target 扫描整张 run_mutations，现明确使用现有对象 partial index 及 device/inode 范围。元数据候选沿用既有 canonical，用一次索引查询准备候选事实；路径受影响对象才逐项重算。完整 ordering 审计仍读取全量。

以下为同机 Debug、同 100,000 条生产 Store 夹具、bounded WAL、1,024 批次的 Darwin 进程写入量。单位 MB 为十进制；包含遍历入库、sealing、ledger、提交和报告，清理另列。无真实文件 stat/原生事件回放，不能外推本机 16.39 GB。

| 后续轮负载 | 全代重建：扫描写入 / 时间 | W6：扫描写入 / 时间 | 全代清理 / W6 清理 |
| --- | ---: | ---: | ---: |
| 零变化 | 171.87 MB / 5.08 s | 0.352 MB / 2.29 s | 57.00 MB / 0.016 MB |
| 3% 对象变化 | 206.17 MB / 5.97 s | 29.42 MB / 2.80 s | 58.28 MB / 0.201 MB |
| 100% 对象变化（独立对照） | 420.37 MB / 11.79 s | 326.01 MB / 19.68 s | 58.28 MB / 5.80 MB |

零变化 + 3% 两轮含清理共约 **29.99 MB 对 493.32 MB，减少 93.9%**，不包含首次基线与强制 VACUUM。首次基线约 177.5 MB，没有已有库存可复用。100% 变化轮含清理约 331.81 MB 对 478.65 MB，写入减少约 30.7%，但耗时约为对照 1.67 倍；变化集与 ledger 很大时，W6 不能承诺同时更快。这里的“100%”是全部对象元数据变化，不等于全部目录重命名或删除重建。

低变化 W6 峰值 WAL 43.17 MB、RSS 132.71 MB；100% 变化时 WAL 170.04 MB、RSS 315.70 MB。128 MiB 守卫作用于事务之间，不能约束单次原子提交峰值。强制 VACUUM 在低变化夹具另写 73.33 MB，高变化夹具另写 428.47 MB，均不应当作每日必做步骤。

百万条目最终 W6：初始基线 1.966 GB / 45.25 s；零变化 352 KB / 22.97 s；3% 变化 300.10 MB / 29.83 s；峰值 RSS 231.49 MB、WAL 371.59 MB。三轮加清理/强制压缩总测试 121.096 s，详细口径及回归清单见 Testing.md。没有重跑百万条目的全代对照，不外推 100k 的节省比例。仍需发布前验收：真实自然到期任务、签名安装/GUI reconnect、新版本部署一致性；更完整的 rename/create/delete 高变化和物理磁盘不足矩阵、SQLite 页写与临时 I/O 分解也应继续补齐。低变化收益已具备生产适配器证据，高变化的耗时取舍不能隐藏，也不能以放松持久性来弥补。


升级不会立刻缩小现有 SQLite 文件。旧 schema-7 retired generations 仍按恢复窗口清理，已空闲页先复用；原有压缩阈值和七天冷却不变。首次升级后的一次旧代清理可能仍有明显写入，不能把这笔一次性成本算作 W6 每日稳态，也不能把文件大小不降误判为差异持久化未生效。
