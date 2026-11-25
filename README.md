# AgyQuotaBar

一个纯原生（Swift / AppKit）的 macOS 菜单栏小工具，用来实时查看 Antigravity（`agy`）的额度。

菜单栏只显示两个数字，例如 `78|67`：

- 左：Gemini 5 小时窗口剩余额度（%）
- 右：Gemini 每周窗口剩余额度（%）

点击后展开菜单，可看到各额度的重置倒计时，以及 Claude / GPT 分组的额度；底部有「立即刷新」「开机自启动」「退出」。

## 特点

- 无任何外部依赖，不调用外部二进制（仅通过系统自带 `security` 读取钥匙串）
- 自适应轮询：默认每 1 分钟检测；连续 15 次额度无变化则降为每 5 分钟；5 分钟档一旦发现额度变化，立刻回到 1 分钟
- 本地日志 `~/Library/Logs/AgyQuotaBar.log`，自动清理 3 天前的记录
- 不含任何账号、令牌或 OAuth 凭据；所有凭据只在运行时从你本机读取

## 要求

- macOS 12+，已安装 Xcode Command Line Tools（`xcode-select --install`）
- 已安装并登录过 `agy`（登录凭证保存在钥匙串，service 为 `gemini`、account 为 `antigravity`）

## 构建与运行

```bash
./build.sh
open build/AgyQuotaBar.app
```

首次读取钥匙串时，系统会弹窗询问是否允许访问，请选择允许。

## 凭据说明（脱敏设计）

本仓库**不包含** OAuth Client ID / Secret。

- 默认：只读取 `agy` 保存在钥匙串里的 access token。`agy` 在使用时会自动刷新它；若令牌已过期，菜单栏会提示「请运行一次 agy 刷新」。
- 可选：如果你希望本工具自己刷新令牌，请提供你自己的 OAuth Client，二选一：
  - 环境变量 `AGY_OAUTH_CLIENT_ID` / `AGY_OAUTH_CLIENT_SECRET`
  - 配置文件 `~/.config/agyquotabar/oauth.json`：

    ```json
    { "client_id": "...", "client_secret": "..." }
    ```

## 免责声明

- 本项目为非官方的个人工具，与 Google 无关。
- 它调用的是 Antigravity 内部（非公开文档）的额度接口，接口随时可能变化或失效；使用风险自负。
- 请勿提交、分享你的钥匙串内容、令牌或 `oauth.json`。

## 许可证

[MIT](LICENSE)
