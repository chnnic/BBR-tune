# BBR 同步维护说明

`BBR-tune` 是从 `chnnic/SSH-Hardening` 中提取的独立 BBR TCP 调优工具。

## 源头关系

- 主仓：`chnnic/SSH-Hardening`
- 独立仓：`chnnic/BBR-tune`
- BBR 逻辑源头：`SSH-Hardening.sh` 中的 `BBR TCP 调优模块`
- 独立脚本入口：`bbr-tune.sh`

维护时默认以 `SSH-Hardening` 的 BBR 模块为源头，`BBR-tune` 跟随同步。主仓的 SSH、Fail2ban、DDNS、Caddy、NFT 等非 BBR 更新，不需要自动抬升 `BBR-tune` 的同步版本。

## 同步原则

1. BBR 行为改动优先进入 `SSH-Hardening`。
2. 将主仓 BBR 模块同步到 `BBR-tune`。
3. 保留 `BBR-tune` 独立运行所需包装层：
   - bash 解释器守卫
   - root 检查
   - 包管理器 helper
   - 服务管理 helper
   - 容器检测 helper
   - 脚本末尾直接进入 `bbr_menu`
4. 同步后更新 README 的同步版本说明。
5. 两边都运行语法检查。

## 最小检查

```bash
bash -n SSH-Hardening.sh
bash -n bbr-tune.sh
```

如改动涉及 `tc`、`sysctl`、systemd service、容器检测或发行版兼容，需在变更说明中写明手动验证范围。
