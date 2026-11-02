# GEMM 扫描实验

在项目根目录运行：

```bash
python lab/full.py -j 24 --dry-run  # 只列出计划，不编译或启动仿真
python lab/full.py -j 24            # 服务器上运行，最多并发 24 个仿真任务
```

`full.py` 覆盖 `static`、`dynamic`、`rect_static`、`rect_dynamic`、
`static_staticmn` 五组原有扫描实验，并默认接入后文的独立 `ablation` 实验。每组原有实验均包含以下扫描：

| 实验目录 | 扫描维度 | 固定维度（默认值） |
| --- | --- | --- |
| labM | M | N=1024，K=1024 |
| labN | N | M=16，K=1024 |
| labK | K | M=16，N=1024 |
| labM64N | M | N=64，K=1024 |
| labM64K | M | N=1024，K=64 |
| labM64NK | M | N=64，K=64 |

三个新增实验沿用 `--m-values`（或 `M_VALUES`），默认扫描
`1 4 16 32 64 128 256 512`，N/K 固定为表中数值，不受
`--n-default` / `--k-default` 影响。

结果写入 `data/<实验组>/<实验目录>/`，文件名沿用各组的硬件参数、
M/N/K 和 Count 命名规则；日志写入 `data/<实验组>/log/`，
并在文件名中包含实验目录名。脚本自动跳过结果文件已经存在的任务，
补充缺失数据；使用 `--force` 可重新运行已有结果对应的任务。

每组内先生成原有 labM、labN、labK，再依次生成三个新增扫描。
每次扫描按扫描值降序、同一值下交错硬件配置的顺序调度；
全部硬件预编译完成后，共用一个仿真线程池。
新增扫描复用现有硬件可执行文件。

`full.py` 的预编译阶段使用一个跨实验组的构建线程池，同一实验组的相同硬件只提交一次。
每个构建任务使用 Verilator `--build-jobs 4` 驱动编译器并行构建，
同时最多构建 `max(1, --jobs // 4)` 个配置。例如 `-j 24` 同时构建最多 6 个配置，
每个配置内部使用 4 个编译进程；`--jobs` 不足 4 时仍运行一个四进程构建任务。
构建全部成功后才启动仿真，仿真阶段仍最多并发 `--jobs` 个任务。
`--rebuild` 在预编译阶段对每个硬件执行一次，仿真子进程复用已构建的可执行文件。
`--no-prebuild` 跳过这个显式构建线程池，沿用按需构建模式。
`--dry-run` 会列出构建数、并行构建数和单构建内部进程数，不启动编译器。

默认配置下，static/dynamic 各有 5 个硬件配置，其余三组各有 3 个。
因此 M 扩展扫描新增 456 个任务，原有扫描合计 798 个任务（每任务 Count=100）。
各组也可通过自己的 `run_axis_sweeps.py --dry-run` 单独检查任务计划。


## 调度与容量消融实验

新增实验位于 `lab/ablation/`，使用独立的结果目录和构建目录。默认完整矩阵
包含 **298 个去重后的任务、53 种硬件/发射策略构建**；加上原有 798 个任务，
`full.py` 默认生成 **1,096 个任务**。三种策略分别为 static 82 个、dynamic 108 个、
dynamic_inorder 108 个。正式矩阵在研究类别筛选前去重计数，上限为 299 个任务，
修改配置后超过上限会明确报错。Count 默认仍为 100。

| 研究内容 | 去重后贡献的任务数 |
| --- | ---: |
| 三种硬件、六种规模的固定延迟基线和空闲统计 | 54 |
| L4/W32 的重点延迟实验 | 126 |
| L4/W32 的固定延迟容量扫描（扣除 6 个共享基线） | 88 |
| 少量容量配置的长尾验证 | 30 |
| 合计 | 298 |

### 运行与验证

```bash
# 本地有界验证：仅运行新增实验的 smoke，最多 40 个小规模仿真任务。
# smoke 要求显式选择 ablation，且 Count 必须为 1 或 2。
python lab/full.py --experiments ablation --ablation-profile smoke --count 2 -j 2

# Python 控制逻辑、延迟模型和两种 GEMM 发射策略的定向测试；不运行完整矩阵。
python lab/ablation/verify.py

# 额外检查三种正式 lane/width × 三种策略的 RTL；可用 --smoke 接着运行有界验证。
python lab/ablation/verify.py --lint

# 完整矩阵只列计划，不建目录、不编译、不启动仿真。
python lab/full.py -j 24 --dry-run

# 迁移服务器后：识别原有数据，补齐新增实验和缺失的原有任务。
python lab/full.py -j 24

# 只补充新增实验；或只选择某类研究。
python lab/full.py --experiments ablation -j 24
python lab/full.py --experiments ablation --ablation-studies capacity -j 24

# 只保留原有五类扫描。
python lab/full.py --experiments static,dynamic,rect_static,rect_dynamic,static_staticmn -j 24

# 汇总 smoke 或正式结果：CSV、Markdown 和 SVG。
python lab/ablation/summarize.py --data-root data/ablation/smoke
python lab/ablation/summarize.py --data-root data/ablation/full
```

也可直接运行 `python lab/ablation/run_experiments.py`，参数与 `full.py` 的
消融相关参数一致；它复用同一个任务调度器。

`--ablation-config` 指定 JSON 配置，默认使用 `lab/ablation/defaults.json`。
配置包含典型 MNK、硬件基线、容量比例、平均延迟、seed 和仿真超时。
内部构建默认使用四进程（`build_jobs=4`）；`full.py` 按上述统一预算调度所有实验组。
`shapes` 和 `hardware` 定义完整基线范围；`latency_lanes` / `latency_shapes`、
`capacity_lanes` / `capacity_shapes` 分别选择详细研究的硬件与规模子集。
`delay_means` / `seeds` 控制重点延迟实验；`capacity_stress_*` 独立控制长尾容量验证。
`--ablation-data-root` 可替换结果根目录；构建根目录可通过
`ABLATION_BUILD_ROOT` 设置，默认 `/tmp/ooogemm_ablation/`。
原有的 `--m-values/--n-values/--k-values` 只控制原有扫描；新增实验的 MNK 来自配置。
`--count` 同时作用于所选实验，默认 100。

smoke 使用 L1/W8、SUBTILE_K=8、Count≤2，覆盖 `1×8×8`、`16×16×16`、
`17×9×9`，以及容量单因素、接近物理容量的逻辑容量。另有 L4/W32、
`16×64×64` 的三种策略验证。它验证功能与统计，不用于推断正式规模的收益。
smoke 的宿主 C++ 使用 `-O0` 以缩短编译时间，正式实验使用 `-O2`；初始化代码使用 `-O0`。
编译优化级别记录在 spec 中并参与构建和运行标识，不改变 RTL 周期口径。
`data/ablation/smoke/` 作为本地验证产物加入 `.gitignore`，正式数据沿用仓库原有管理方式。

### 比较对象与默认矩阵

- `static`：现有静态设计，保留独立 LOAD/GEMM/OUTPUT 流和 ping-pong 分区。
- `dynamic`：现有动态解析、重命名、LOAD FIFO、OUTPUT 依赖和 GEMM 乱序仲裁。
- `dynamic_inorder`：只将 GEMM 发射限制为所有已接收 GEMM 的全局入队顺序；
  较早 GEMM 未就绪时，较晚 GEMM 不能越过。其余队列、预取、重命名和输出规则不变。

因此 `dynamic/static` 表示整体架构收益；`dynamic/dynamic_inorder` 才用于
隔离 GEMM 乱序发射的收益。顺序对照限制调度器的 GEMM 发射顺序，阵列自身的
lane 分配和开始执行规则保持不变。

| lane/width | A/B 物理条目数（各自） | ACC 物理条目数 | 默认动态 A/B/ACC 逻辑条目数 | 每个 GEMM slot 分组的 ACC 数 |
| --- | ---: | ---: | --- | ---: |
| L1/W64 | 8 | 8 | 4/4/4 | 1 |
| L4/W32 | 16 | 32 | 8/8/16 | 2 |
| L16/W16 | 32 | 128 | 16/16/64 | 4 |

三组均为每周期峰值 4096 FMAC；SUBTILE_K=32，读总线为 1024 bit。
STORE_ROWS_PER_CYCLE 分别为 1、2、4。
动态调度器的 GEMM slot 深度固定 16，LOAD FIFO 深度固定 16，完成跟踪深度固定 64。
扫描时冻结表中的 ACC 分组大小；slot 总数仍随 ACC 物理容量变化，并由元数据中的
容量和分组大小确定，因此容量结果也包含相应队列规模的影响。

典型 MNK 为 `16×1024×1024`、`64×1024×1024`、`256×256×256`、
`64×64×1024`、`64×1024×64`、`64×64×64`。

- **idle / 基线**：三种策略、三种硬件、上述六种规模均保留固定延迟 4、seed=1，
  共 54 个基线任务。全部新增实验都会统计空闲原因。
- **latency**：除全部基线外，详细延迟研究仅使用 L4/W32，规模为
  `16×1024×1024`、`256×256×256`、`64×64×64`，平均延迟取 32、128。
  每个均值保留固定分布 seed=1，以及均匀和长尾分布 seed=1/2/3，共增加 126 个任务。
- **capacity**：仅使用 L4/W32、`16×1024×1024` 和 `256×256×256`。
  固定延迟 4 下，分别改变 A 物理、B 物理、ACC 物理至基线的 3/4、3/2，
  以及动态 A 逻辑、B 逻辑、ACC 逻辑至基线物理容量的 1/4、3/4，并保留基线。
  同步 A/B 和 ACC 两类局部交叉采用物理比例 3/4、3/2，逻辑比例 1/4、3/4；
  排除逻辑容量不小于物理容量的组合。静态设计仅改变物理容量，逻辑容量保持为物理容量的一半。
  固定延迟容量研究共 94 个任务，其中 6 个与基线共享，实际增加 88 个。
- **capacity 长尾验证**：平均延迟 32、seed=1，只重测单因素压力点。
  动态两种策略分别验证 A/B/ACC 物理容量缩至 3/4、逻辑容量增至基线物理容量 3/4 的六个配置；
  静态策略验证三个物理容量缩至 3/4 的配置。两个规模共增加 30 个任务。

单独选择研究类别时，`--ablation-studies latency` 生成 180 个任务，`idle` 生成 54 个，
`capacity` 生成 124 个；这些集合共享部分基线，不能直接相加作为总任务数。

单因素和交叉扫描中相同的运行会去重；研究类别不参与运行标识。
精简后的任务复用原有运行标识和已完成数据；未入选任务的已有数据保留。
动态两种策略的容量配置完全配对。修改逻辑容量可能改变 blocksel 分块和读请求量，
结果 JSON 同时记录选择的 BM/BN 直方图、队列布局和请求数量，以区分分块收益与调度收益。

### 延迟模型

对目标均值 μ，固定延迟为 μ，均匀延迟取整数 `[1,2μ−1]`；长尾以 15/16 概率
取 1，以 1/16 概率取 `16μ−15`。它们的**理论均值**相同，有限样本均值可能不同。
结果分别记录抽样延迟和“请求握手至响应握手”的实际延迟的均值、P50、P95、P99 和最大值。

样本使用确定性的 64-bit 混合函数，键包含 seed、读地址和该地址在当前运行中的
请求次数。不同调度顺序对同一地址的第 n 次请求使用相同样本；不同分块产生的
访问序列不必相同。响应每周期最多一个，允许乱序返回；等待握手期间保留同一个
响应。请求端和写总线保持原有 ready 行为。目前 loadunit 的响应 ready 恒为 1。

### 统计口径

窗口为首个命令被接受至最后一个输出写握手，包含首尾周期，与原有吞吐统计一致。

- `lane_active`：lane 向阵列输送 K 数据的活跃周期数；分母为窗口周期数 × lane 数。
- `mac_active`：PE 实际乘加输入的 valid 数；分母为窗口周期数 × lane 数 × width²。
  这里包含边界 tile 的填充计算。`useful_utilization` 用请求的 M×N×K×Count 计算，
  与包含填充的 `mac_utilization` 分开报告。
- `whole_array_idle_cycles`：当前周期没有任何 MAC 有效输入的周期数。
- `lane_idle` / `mac_idle`：互斥的主原因计数；活跃数加全部空闲数必须等于分母。
  `mac_idle_share` 是占全部执行机会的比例，`mac_idle_composition` 是占空闲机会的比例。
- `blocker_cycles`：当前前端状态的原始阻塞事件，可重叠，不是互斥分解。
- `phases`：截至首次 MAC 活跃的采样周期为 warmup，全部 MAC 工作完成后为 drain，中间为 steady。
  每个阶段分别保留活跃和原因计数。

优先识别局部 lane 的操作数传递、ACC 重用间隔和开始端口竞争；然后识别上游
GEMM 队头阻塞、A/B 数据等待、A/B/ACC 分配不足、输出回收和控制间隙。
静态设计额外记录波次/边界等待。原因标签沿 row skew 和 PE 转发流水传播，
并断言标签与实际 MAC valid 对齐；因此不会直接拿同周期发射端的状态解释 MAC 空闲。
这些标签描述观察到的阻塞机制，不是对多个同时存在的限制做反事实因果分配。

默认仅写汇总。添加 `--ablation-trace` 可输出逐周期 `cycles.csv`；trace 设置参与
结果标识，因此开启 trace 会生成单独的运行记录。此开关仅影响新增实验。

### 结果、补跑与汇总

每次运行写入 `data/ablation/<full|smoke>/<策略>/<硬件标识>/<运行标识>/`：

- `result.json`：包含完整 spec、性能指标、原因计数、阶段、分块和延迟统计，是唯一完成标记。
- `metrics.txt`：保留吞吐、延迟、读写总线利用率四行，方便对照原有指标。
- `run.log`：命令、过程日志和退出状态；启用 trace 时另有 `cycles.csv`。

spec 包含全部实验硬件参数、发射策略、延迟分布/均值/seed、MNK、Count、trace
和统计版本。构建缓存还包含相关 RTL、C++ 和监测头文件的内容哈希。
结果只在子进程成功退出并通过计数守恒等检查后，以原子替换方式发布。
损坏、缺字段或参数不符的结果会补跑；失败、超时或中断不会产生完成标记。
`--force` 可以重跑所选任务；若强制重跑失败，旧完成标记也不会保留。
修改统计含义或结果格式时需要递增 `SCHEMA_VERSION`，避免复用旧口径结果。

汇总输出 `runs.csv`、按 seed 聚合均值/标准差的 `aggregate.csv`、配对比较的
`comparisons.csv` 和 `report.md`，以及各规模/硬件的延迟曲线、MAC 空闲堆叠图和
动态相对 GEMM 顺序对照的容量热图。`--no-plots` 可只输出表格。
绘图需要 NumPy 和 Matplotlib；实验运行器和 CSV 汇总使用 Python 标准库。

静态比较按相同物理容量配对，并通过 `static_logical_match` 标记逻辑容量是否相同；
动态顺序对照匹配全部硬件参数。比值大于 1 表示动态吞吐更高，低于 1 的点照常保留。
`output_hash` 是按输出地址计算、与输出次序无关的校验值，用于检查配对执行的一致性，
不是独立的浮点数值参考模型。单个 seed 的标准差为 0，不代表置信区间；
正式性能结论应使用完整规模数据，而非 smoke 的结果。

### 本次小规模验证发现

40 个 smoke 任务的命令完成、内存事务、计数守恒和 MAC 标签对齐检查均通过，
动态乱序与 GEMM 顺序对照的 15 个配对输出校验值全部一致。
其中 static/dynamic 的 14 个可配对结果中，有 4 个完整写回载荷校验值不同：
涉及 `17×9×9` 的固定/长尾延迟，以及 ACC 物理容量为 6 的两个动态配置。

已使用修改前保存的原始 RTL 和测试程序快照，复现 `17×9×9`、L1/W8、
A/B/ACC=8、Count=2 的 static/dynamic 写回差异；同一架构的修改前后写回数据逐项相同。
这些新增监测不会修复或掩盖原有数值一致性问题。原有五类扫描的配置与默认硬件行为保持原样；
差异的根因和小容量配置的完整数值正确性需要单独排查。

`runs.csv` 和 `comparisons.csv` 保留原始吞吐比值及 `*_output_match` 标记，便于定位；
`aggregate.csv` 的收益均值/标准差和报告的收益表仅使用输出校验值相同的配对，
并提供 `*_pairs` 表示有效配对数。校验值相同仍不等同于通过独立数值参考模型验证。
