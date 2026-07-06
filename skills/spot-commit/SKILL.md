---
name: spot-commit
description: Commit changes to the spot repository, handling the cpp-infra submodule first, running clang-format, and flagging anything unsuitable.
---

# Spot Commit

提交 spot 仓库的改动。严格遵守子模块顺序、格式化、脏文件审查流程。

## 流程

### 1. 检查子模块改动

```bash
cd cpp-infra && git status --short && git diff --stat HEAD
```

如果 cpp-infra 有未提交的改动（包括 untracked 文件），**必须先提交子模块**，再提交 spot。

### 2. 检查 spot 层改动

```bash
git status --short && git diff --stat HEAD
```

注意 `m cpp-infra` 这条——它表示子模块指针变了，提交 spot 时必须包含。

### 3. 审查脏文件

逐个检查所有 modified / untracked 文件。对于每个文件判断：

- **适合提交**: 源代码改动、测试、CMakeLists、文档
- **不适合提交**: build 产物、临时文件、本地配置、IDE 文件

如果有文件不适合提交：
- 停下来，告诉用户哪些文件有问题，为什么
- 让用户决定：加到 `.gitignore` 还是删掉
- 用户确认后再继续

### 4. clang-format

格式化所有 C++ 文件（排除 build 目录和第三方代码）：

```bash
find . \( -name ".git" -o -name "build" -o -name "build-*" -o -name "kcex-marketdata" -o -name "third_party" -o -name "logs" \) -prune -o \( -name "*.cpp" -o -name "*.hpp" -o -name "*.h" -o -name "*.cc" -o -name "*.hh" \) -print0 | xargs -0 -r clang-format -i
```

格式化后重新检查 `git diff`——如果有纯格式变动，和用户确认后再继续。

### 5. 提交子模块

```bash
cd cpp-infra
git add <改动文件>
git commit -m "<描述>"
```

commit message 规范：
- 格式: `type(scope): summary`
- type: `feat` / `fix` / `refactor` / `test` / `chore` / `docs`
- scope: 用子模块里的目录或模块名，如 `infra` / `tests`
- summary: 中文，简要描述改了什么
- 结尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`

例如:
```
fix(infra): 修复 ssl::stream reactor 泄漏导致 io_context::run() 挂死

Co-Authored-By: Claude <noreply@anthropic.com>
```

如果改动涉及多个独立主题，建议拆成多个 commit。

### 6. 提交 spot

```bash
cd /kcex/cpp/spot
git add <改动文件> cpp-infra
git commit -m "<描述>"
```

commit message 规范同上，scope 用 spot 层的模块名，如 `adapters` / `config` / `strategy` / `tests`。

**必须包含 `cpp-infra` 子模块指针更新**（`git add cpp-infra`）。

### 7. 最终检查

```bash
git status
git log --oneline -3
```

确认：
- 没有遗漏的 dirty 文件
- 子模块 commit 和 spot commit 都在历史里
- 子模块指针指向正确的 commit

## 异常处理

| 情况 | 处理方式 |
|------|---------|
| 子模块有未提交改动但 spot 没有 | 仍然提交子模块，然后更新 spot 的子模块指针 |
| 有不该提交的文件 | 停下来让用户决定 |
| clang-format 产生了纯格式 diff | 告诉用户有多少格式变动，确认是否继续 |
| 子模块有 merge conflict 标记 | 停下来让用户先解决 |
| commit message 不确定怎么写 | 把改动的文件列表和 diff 摘要给用户，让用户写 message |

## 规则

- **不管改动来源**——不管是之前对话改的、用户自己改的、还是其他会话改的，只要是 dirty 且适合提交的，都要提交
- **子模块必须先提交**——否则 spot 的 commit 会指向一个不存在的子模块 commit
- **不要默默跳过**——有异议的文件停下来，不要自己做决定
- **不要 force push**——永远不用 `--force`
