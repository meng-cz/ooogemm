# GEMM 扫描实验

在项目根目录运行：

```bash
python lab/full.py -j 24 --dry-run  # 只列出计划，不编译或启动仿真
python lab/full.py -j 24            # 服务器上运行，最多并发 24 个仿真任务
```

`full.py` 覆盖 `static`、`dynamic`、`rect_static`、`rect_dynamic`、
`static_staticmn` 五组实验。每组实验均包含以下扫描：

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

默认配置下，static/dynamic 各有 5 个硬件配置，其余三组各有 3 个。
因此新增 456 个任务，总计 798 个任务（每任务 Count=100）。
各组也可通过自己的 `run_axis_sweeps.py --dry-run` 单独检查任务计划。
