// 开发调试用示例文档（仅浏览器环境作为初始内容；App 内由 native 通过 editor.setContent 注入）
export const DEMO_DOC = `# KV Cache 调研笔记

自回归解码时，每步都要对历史所有 token 的 \`K/V\` 做注意力，因此把 **KV Cache** 驻留显存是避免重复计算的关键。但显存占用随 *batch size × 序列长度* 线性膨胀，很快成为吞吐瓶颈，详见 [vLLM 论文](https://arxiv.org/abs/2309.06180)。

## vLLM：PagedAttention

**PagedAttention** 借鉴操作系统的 \`虚拟内存 + 分页\` 思想：

- 逻辑块连续、物理块离散，显存浪费压到 **< 4%**
- 共享前缀映射同一物理块，引用计数 + Copy-on-Write
- ~~需要预留最大长度空间~~ 按需分配，消除内部碎片

## 代码示例

\`\`\`python
from vllm import LLM, SamplingParams

llm = LLM(model="Qwen/Qwen2.5-7B", gpu_memory_utilization=0.9)
out = llm.generate(prompts, SamplingParams(max_tokens=512))  # block 自动分页管理
\`\`\`

## 系统对比

| 系统 | 卸载目标 | 预取策略 | 备注 |
| --- | --- | --- | --- |
| vLLM | 驻留 GPU | — | PagedAttention 基座 |
| LMCache | CPU / Disk | 层间流水预取 | HybridBackend |
| Mooncake | CPU / SSD / 远端 | 前缀复用 | KVCache 池化 |

---

## 待办

- [x] 精读 vllm.pdf 第 4 节
- [ ] 复现 LMCache 卸载实验
- [ ] 整理 Mooncake 配置笔记

> “PagedAttention divides the request's KV cache into blocks ... near-zero waste (less than 4%).”
`;
