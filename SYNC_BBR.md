# BBR 同步维护说明

`BBR-tune` 是从 `chnnic/SSH-Hardening` 中提取的独立 BBR TCP 调优工具。

## 源头关系

- 主仓：`chnnic/SSH-Hardening`
- 独立仓：`chnnic/BBR-tune`
- BBR 逻辑源头：`SSH-Hardening/src/modules/bbr.sh`
- 独立脚本入口：`bbr-tune.sh`

维护时默认以 `SSH-Hardening` 的 BBR 模块为源头，`BBR-tune` 跟随同步。主仓的 SSH、Fail2ban、DDNS、Caddy、NFT 等非 BBR 更新，不需要自动抬升 `BBR-tune` 的同步版本。

## 同步原则

1. BBR 行为改动优先进入并提交到 `SSH-Hardening`。
2. 使用同步脚本将主仓 BBR 模块提取到 `BBR-tune`。
3. 保留 `BBR-tune` 独立运行所需包装层：
   - bash 解释器守卫
   - root 检查
   - 包管理器 helper
   - 服务管理 helper
   - 容器检测 helper
   - 脚本末尾直接进入 `bbr_menu`
4. 同步后更新 README 的功能说明和版本沿革。
5. 两个仓库必须在同一批工作中分别提交并推送，不允许只更新主仓。

`bbr-tune.sh` 中以下标记之间的内容由同步脚本管理，不应手工修改：

```text
# BEGIN SYNCED BBR MODULE - DO NOT EDIT BY HAND
# END SYNCED BBR MODULE
```

`UPSTREAM.env` 记录上游仓库、固定提交、版本和模块 SHA256。CI 会重新提取固定提交并逐字比较。

## 同步命令

假设两个仓库位于同级目录：

```bash
cd BBR-tune
scripts/sync-from-upstream.sh ../SSH-Hardening
```

也可以不传本地路径，脚本会克隆主仓当前 `main`：

```bash
scripts/sync-from-upstream.sh
```

上游 BBR/core 修改必须先提交，避免 `UPSTREAM.env` 指向不包含实际改动的旧提交。

## 最小检查

```bash
bash -n bbr-tune.sh
shellcheck --severity=warning -x bbr-tune.sh scripts/sync-from-upstream.sh tests/smoke.sh
scripts/sync-from-upstream.sh --check ../SSH-Hardening
tests/smoke.sh
```

如改动涉及 `tc`、`sysctl`、服务持久化、容器检测或发行版兼容，需在变更说明中写明未在真实 VPS 上执行的破坏性测试范围。
