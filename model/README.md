# 模型静态矩阵运算 Trace 说明

## 1. 数据内容

本目录记录远端 Hugging Face 缓存中 25 个模型的静态逻辑矩阵运算，共 14,548 条记录。

- `manifest.csv`：模型索引，说明每个模型的类别、trace 文件、记录数、阶段和覆盖状态。
- `all_traces.csv`：25 个模型的全部记录合并在一个文件中，共 14,548 条数据行；文件另有一行表头。
- `traces/*.csv`：每个模型单独一个 trace，共 25 个文件。

模型范围包括：

- 13 个 causal language model：Llama、Qwen、CodeLlama、Mistral，以及 AWQ 版本；
- 6 个 Whisper 语音识别模型；
- 2 个文本 embedding 模型：BGE、MPNet；
- Wav2Vec2-BERT、CAMPPlus、MaskGCT semantic codec 和 BigVGAN 各 1 个。

这些文件是**静态逻辑 trace**，不是 vLLM、CUDA、cuBLAS 或某块 GPU 上的 runtime kernel trace。生成过程中没有执行模型数值推理，也没有把完整权重加载到 GPU。

静态 trace 描述模型语义中的矩阵运算。运行时可能把多个逻辑操作融合成一个 kernel，也可能把一个逻辑操作拆成多个 kernel，因此不能根据本数据推断实际 kernel 数量、执行时间或显存流量。

## 2. MNK 约定

所有普通矩阵乘统一采用：

```text
A[M, K] × W[K, N] -> C[M, N]
```

因此：

- `M`：输出行数，通常由 batch、token 数、音频帧数或输出位置数决定；
- `N`：输出特征维度；
- `K`：归约维度，即两个输入矩阵相乘的公共维度。

例如 Llama 3.1 8B 的首层 Q projection：

```text
M = B*S, N = 4096, K = 4096
```

表示：

```text
hidden[B*S, 4096] × W[4096, 4096]
```

对于 attention 的 batched matmul，`batch_dims` 单独记录批维。例如：

```text
batch_dims = B*QH, M = S, N = S, K = 128
```

表示每个 batch、每个 query head 分别执行一个 `Q[S,128] × K^T[128,S]`。不能只看 MNK 而忽略 `batch_dims`。

## 3. Trace CSV 字段

| 字段 | 含义 |
|---|---|
| `model` | Hugging Face cache 中的模型仓库名。 |
| `op_id` | 当前模型 trace 内的矩阵操作序号，从 1 开始连续编号。 |
| `phase` | 所属推理阶段，例如 `prefill`、`decode_step`、`encoder`。 |
| `layer` | 模型层号或结构阶段名，例如 `0`、`frontend`、`output`。 |
| `module` | 逻辑模块或权重模块路径。 |
| `op_kind` | 矩阵操作类别。详见下一节。 |
| `batch_dims` | 未折叠到 MNK 中的 batched/grouped 维度。 |
| `M`,`N`,`K` | 按 `A[M,K] × W[K,N]` 约定记录的矩阵规模。 |
| `deps` | 当前操作依赖的前序矩阵操作 `op_id`；多个序号用分号分隔。 |
| `weight` | 该操作使用的权重名。 |
| `weight_shape` | checkpoint/PyTorch 中的权重存储 shape。 |
| `provenance` | 本行结构和尺寸的推导依据。 |
| `notes` | 不能放入 MNK 的补充语义和限制。 |

`all_traces.csv` 中不同模型的 `op_id` 会重新从 1 开始，因此唯一定位一行时应使用 `(model, op_id)`，不能只使用 `op_id`。

## 4. 留空字段是什么意思

空白**不表示 0**，也不表示该操作可以删除。不同字段的空白含义如下。

### `batch_dims` 留空

表示该操作已经按普通二维 GEMM 记录，batch 或序列位置已经折叠进 `M`，没有额外需要声明的 batched/grouped 维度。

例如：

```text
batch_dims = 空
M = B*S
```

这里 batch 已经包含在 `B*S` 中。

相反，attention 通常保留 `batch_dims=B*QH` 或 `B*heads`，因为每个 head 执行一个独立矩阵乘。

### `deps` 留空

表示当前行没有依赖**本 trace 中更早记录的矩阵操作**，通常是以下情况之一：

- 当前 phase 的第一个 projection；
- 输入直接来自 token embedding、音频输入、KV cache 或其他外部输入；
- 前驱只有 normalization、reshape、embedding lookup 等未作为矩阵行记录的操作。

它不表示该操作没有输入，也不表示它在真实程序中可以任意调度。

`deps` 只记录矩阵操作之间的逻辑依赖。LayerNorm、RMSNorm、RoPE、mask、softmax、激活、残差、reshape、transpose、concat 和 pooling 等非矩阵操作不会单独占一行，但其数据流约束已经桥接到后续矩阵操作。例如 attention 的 `PV` 依赖 `QK`，其中的 mask 和 softmax 虽然没有独立 `op_id`，并不代表它们不存在。

### `weight` 和 `weight_shape` 留空

表示该操作是两个激活张量之间的矩阵乘，没有独立的模型参数。例如：

- attention 的 `Q × K^T`；
- attention probability 与 `V` 的乘法。

因此，`weight` 和 `weight_shape` 同时为空通常是“该操作没有权重”，不是“权重信息丢失”。

当 `weight_shape` 非空时，它表示 checkpoint/PyTorch 的存储方向：

- Linear 通常存为 `[out_features, in_features]`；
- Conv1d 通常存为 `[Cout, Cin/groups, kernel]`；
- Conv2d 通常存为 `[Cout, Cin/groups, Kh, Kw]`。

该存储方向不等于 MNK 书写方向。例如 Linear 权重存储为 `[N,K]`，逻辑矩阵乘仍按 `A[M,K] × W[K,N]` 记录。

### `notes` 留空

表示该行没有额外限定事项；MNK、依赖和其他字段仍然完整有效。

### 不应留空的字段

以下字段在当前数据中不应为空：

```text
model, op_id, phase, layer, module, op_kind, M, N, K, provenance
```

生成后已检查全部 14,548 行：这些字段没有空值，`op_id` 连续，所有 `deps` 均指向同一模型中更早的操作。

## 5. `op_kind` 类型

| `op_kind` | 含义 |
|---|---|
| `linear` | 全连接/投影层的逻辑 GEMM。 |
| `batched_matmul` | 带 batch/head 维度的矩阵乘，主要用于 attention 的 QK 和 PV。 |
| `einsum_matmul` | 可归约为矩阵乘的 einsum，例如 Wav2Vec2-BERT relative-key score。 |
| `matmul` | 普通的激活或 codebook 相关矩阵乘。 |
| `conv1d_im2col_equivalent` | Conv1d 的逻辑 im2col 矩阵等价形式，不代表运行时真的显式生成 im2col。 |
| `conv2d_im2col_equivalent` | Conv2d 的逻辑 im2col 矩阵等价形式。 |
| `grouped_conv1d_im2col_equivalent` | grouped/depthwise Conv1d；分组信息记录在 `batch_dims`。 |
| `conv_transpose1d_scatter_equivalent` | ConvTranspose1d 的 producer-side 矩阵形式；矩阵结果随后需要 overlap-add/scatter。 |

卷积等价行必须结合 `notes` 和 `weight_shape` 阅读。卷积的 stride、padding、dilation、groups 和 scatter 语义不会仅靠三个 MNK 数字完整表达。

## 6. 符号变量

| 符号 | 含义 |
|---|---|
| `B` | batch size。 |
| `S` | 文本序列长度。 |
| `KV` | causal language model 当前有效 KV cache 长度，decode 时通常包括当前 token。 |
| `KV_dec` | Whisper decoder self-attention 的有效 KV cache 长度。 |
| `QH` | query attention head 数；GQA 模型中可能大于 KV head 数。 |
| `heads` | attention head 数。 |
| `T_audio` | Whisper 输入 mel 帧数。 |
| `T_enc` | Whisper encoder 输出帧数；标准 Whisper 前端中约为 `ceil(T_audio/2)`。 |
| `T_dec` | Whisper decoder token 数。 |
| `T_feat` | 音频/语音模型的输入特征帧数。 |
| `T_tdnn` | CAMPPlus TDNN 阶段的时间长度。 |
| `L_codec` | MaskGCT semantic codec 的符号序列长度。 |
| `L0`…`L6` | BigVGAN 各级上采样前后的符号长度。 |
| `F0`…`F3` | CAMPPlus 频率轴经过各级卷积后的尺寸。 |

符号表达式可以在选定 workload 后代入。例如 `B=1,S=2048` 时，`M=B*S` 可实例化为 2048。当前文件没有擅自固定 batch、输入长度或生成长度，因此同一份 trace 可用于多种 workload。

## 7. 各 phase 的含义

### Causal language model

- `prefill`：完整 prompt 一次前向；projection 和 FFN 的 `M=B*S`，attention QK 的 `M=N=S`。
- `decode_step`：带 KV cache 的单 token 解码一步；projection 和 FFN 的 `M=B`，attention query 长度为 1，key/value 长度为 `KV`。

这两个 phase 是两个独立场景模板，不表示先把 CSV 中全部 prefill 行执行完，再把所有 decode 行只执行一次。生成多个 token 时，需要按每一步更新后的 `KV` 重复实例化 `decode_step`。

### Whisper

- `encoder`：音频卷积前端和 encoder Transformer。
- `decoder_prefill`：decoder 已知 token 序列的完整前向，同时建立 self-attention 和 cross-attention cache。
- `decoder_decode_step`：使用已有 self-attention/cross-attention cache 的单 token 解码一步。

### 其他模型

- `encode`：BERT、MPNet、Wav2Vec2-BERT encoder。
- `speaker_encode`：CAMPPlus speaker embedding 路径。
- `codec_encode`、`codec_decode`：缓存中 MaskGCT semantic codec 的编码和解码部分。
- `vocoder`：BigVGAN generator 路径。

## 8. `provenance` 和覆盖状态

`provenance` 表示每行的依据：

- `config+architecture`：由本地模型配置和对应标准架构推导；
- `variant+standard_whisper`：faster-whisper cache 配置不包含完整 Transformer 参数，按已识别的 Whisper variant 和标准 Whisper 架构展开；
- `checkpoint_shape+official_CAMPPlus_forward`：结合 checkpoint shape 与 CAMPPlus 官方 forward 结构；
- `checkpoint_shape+standard_BigVGAN_generator_topology`：结合 checkpoint shape、配置和标准 BigVGAN generator 拓扑；
- `checkpoint_shape+inferred_codec_topology`：MaskGCT 仅依据缓存的 semantic codec 权重结构推导，可信范围较窄。

`manifest.csv` 的 `status` 含义：

- `complete_logical_static`：指定标准推理路径的逻辑矩阵操作已展开；不等价于 runtime kernel 完整。
- `complete_logical_static_from_variant`：依据已识别模型 variant 展开标准逻辑结构。
- `complete_static_from_checkpoint_and_official_forward`：结合 checkpoint 和官方 forward 展开。
- `complete_learned_operator_static`：学习型矩阵/卷积操作已覆盖，但不包含固定滤波器等非学习操作。
- `partial_repository_semantic_codec_only`：当前缓存只包含模型的一部分，trace 也只覆盖这一部分。

## 9. 已知边界

- MaskGCT 缓存只有 `semantic_codec/model.safetensors`，因此其 79 行只覆盖 semantic codec，不是完整 MaskGCT 语音生成 pipeline。
- BigVGAN 的学习型 Conv/ConvTranspose 已记录；固定 anti-alias 重采样滤波器未作为逻辑学习型矩阵操作记录。
- Embedding lookup、归一化、激活、softmax、mask、残差、池化、采样和 tokenizer 不属于本 trace 的矩阵行。
- AWQ 模型按反量化后的逻辑 Linear 尺寸记录。AWQ 的 packing、scale、zero point 和融合反量化 kernel 不会改变逻辑 MNK，也没有单独虚构为矩阵乘。
- trace 不描述 tensor parallel、pipeline parallel、continuous batching、FlashAttention、CUDA Graph 或 kernel fusion。
- `deps` 表达逻辑数据依赖，不是精确的 GPU stream/event 调度依赖。
