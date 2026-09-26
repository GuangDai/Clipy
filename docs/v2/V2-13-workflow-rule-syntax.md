# 工作流规则语法

规则文本和可视化编辑器使用同一棵工作流步骤树，Preview、Run 和自动执行也使用同一个执行器。
文本解析成功后才整体替换草稿；出错时保留原有步骤，指出从 1 开始计算的行号和字符列号。
步骤 ID 会重新生成，格式化后再解析保持执行语义，不要求保留注释或原来的分组写法。

这是一种由 Clipy 执行的规则语言，采用 Python 熟悉的缩进、冒号、`if`／`else`、
字符串和布尔运算写法。它不是 Python 解释器，也不支持任意 Python 变量、导入、循环、
网络或进程调用。缩进划分代码块、同层 `else` 对应同层 `if` 的规则参考
[Python 词法规则](https://docs.python.org/3/reference/lexical_analysis.html#indentation)和
[Python 条件语句](https://docs.python.org/3/reference/compound_stmts.html#the-if-statement)。

```python
# 从上到下执行动作。
trim()
if is_text() and contains("TODO") and not contains("archived"):
    replace("TODO", "Done")
    notify()
else:
    trim_lines()
```

条件支持 `is_text()`、`is_image()`、`contains("文本")` 和 `matches(r"正则表达式")`。
`not` 优先于 `and`，`and` 优先于 `or`；括号可以改变顺序。条件从左到右短路求值。
选中的分支处理当前值，分支结束后继续执行外层后续动作。
`elif` 可以继续判断其他条件，内部表示为 Otherwise 中的下一个条件；格式化时可展开为
`else` 和嵌套 `if`，执行语义不变。

```python
if (contains("invoice") or contains("receipt")) and not is_image():
    regex_extract(r"\d+(?:\.\d{2})?")
elif is_image():
    recognize_text()
else:
    pass
```

每条语句占一行。缩进必须使用空格，并与对应的已有层级对齐；格式化统一使用四个空格。
空行和字符串以外的 `#` 注释会被忽略。空分支写 `pass`；空规则也表示没有步骤。
暂不支持同行分支、三引号字符串或跨行函数调用；需要更多条件时可以使用 `elif` 或嵌套 `if`。

动作名称固定使用英文，小写且区分大小写：

| 类型 | 动作 |
| --- | --- |
| 文本 | `trim()`、`uppercase()`、`lowercase()` |
| 行处理 | `trim_lines()`、`remove_empty_lines()`、`unique_lines()`、`sort_lines()` |
| JSON | `pretty_json()`、`compact_json()` |
| 替换与提取 | `replace("原文", "替换文")`、`regex_replace(r"模式", "$1")`、`regex_extract(r"模式")` |
| 图像 | `recognize_text()` |
| 通知 | `notify()` |

通知沿用现有工作流规则：放在条件分支内，在所选分支和剩余动作成功后发送；Preview 不发送通知。
正则替换中的 `$1` 等捕获组由现有正则执行器解释；普通 `replace` 的替换文按字面值处理。

参数可以用单引号或双引号包围。普通字符串支持 `\\`、`\"`、`\'`、`\n`、`\r`、
`\t`、`\a`、`\b`、`\f`、`\v`，以及 `\xNN`、`\uNNNN`、`\UNNNNNNNN` Unicode
转义。`r"..."` 或 `r'...'` 保留反斜杠，适合正则；原始字符串不能以单个未配对的反斜杠结束。
`#`、括号和冒号位于字符串内时都是普通内容。

`disabled:` 保留停用步骤，直接位于该块中的步骤会设为停用。停用条件的子步骤保留各自的启用状态，
重新启用条件时可以恢复原有配置：

```python
disabled:
    if contains("debug"):
        uppercase()
trim()
```

早期保存的平铺条件使用 `require_text()`、`require_image()`、`require_contains("文本")`、
`require_matches(r"模式")` 表示。它们仍在条件不满足时停止整个工作流，不会被改写成跳过单个分支。

不限制固定的步骤数量。规则文本和格式化输出沿用 1 MiB UTF-8 资源预算，每个字符串参数最多
16 KiB；执行时保留原有文本、图像、正则时限和保存定义的资源限制。解析、格式化和树遍历使用显式栈，
并检查取消。语法正确不代表参数已经能执行，例如无效正则仍由既有参数校验和 Preview 提示。

规则文本表示可执行语义；未使用的旧参数不写入文本。若普通动作携带不执行的分支，格式化会明确拒绝，
避免转换时丢弃这些配置。需要完整保留名称、触发方式、来源、时间范围及所有步骤字段时，使用工作流 JSON
导入导出；测试输入和结果不包含在分享文件中。
