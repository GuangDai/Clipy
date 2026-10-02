# xxHash 来源与用途

本目标保留 [xxHash v0.8.3](https://github.com/Cyan4973/xxHash/tree/v0.8.3) 的 `xxhash.h` 和 `xxhash.c`，来源 commit 为 `e626a72bc2321cd320e953a0ccf1584cad60f363`，于 2026-07-22 取得。上游 BSD 2-Clause 版权和许可原文保留在源码头部。

SwiftPM 为 C 编译单元定义 `XXH_INLINE_ALL`，上游实现保持单元内部可见。Clipy 的入口是 `include/xxh3.h` 声明的 `clipy_xxh3_64bits`；上游头文件不作为公共头导出。

指纹只用于剪贴板去重候选查询，最终仍需字节确认，不用于身份、文件验证或仓库基础设施。模块关系见 [架构](../../docs/architecture.md)，实际存储用途见 [存储](../../docs/storage.md)。依赖改动使用 CI 中真实 wrapper 行为测试验证。
