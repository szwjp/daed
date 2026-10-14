# szwjp/daed

> **这是 [daeuniverse/daed](https://github.com/daeuniverse/daed) 的自维护 fork。**
> 目标：自动跟随官方 dae / dae-wing / daed 三层上游，同时保留本 fork 的本地定制。
> 不是什么：不是发布源，不提供 release，不替代上游。

本文件记录**这个 fork 与上游的所有差异，以及为什么这么改**。
官方 README 见 [daeuniverse/daed](https://github.com/daeuniverse/daed#readme)。

---

## 1. 产物结构

三个仓库、一个二进制：

```
daed (React 前端)              ← 本 fork main
  └─ wing/  → daeuniverse/dae-wing   (Go, GraphQL API)   ← submodule 指针
       └─ dae-core/ → daeuniverse/dae (Go + eBPF, tc hook) ← CI 内 pin
```

编译产物是**单个二进制**（约 60MB），三者编译在一起。
面板只通过 GraphQL 操作 dae-wing，dae-wing 通过 Go 依赖调用 dae。

---

## 2. 自动同步机制

`.github/workflows/check-upstream.yml` —— 每天 UTC 00:00（北京 08:00）运行，
也可手动 `workflow_dispatch`。

| 层 | 更新方式 | 有更新时 |
|---|---|---|
| **dae-core** | 改根目录 `dae-core.pin`（一行 40 位 sha） | 自动 bump + 推送 |
| **dae-wing** | `git -C wing checkout` submodule | 自动 bump + 推送 |
| **daed** | `git merge upstream/main` | merge 干净才自动推；冲突则停下 |

**pin 为什么放在 `dae-core.pin` 这种普通文件里**：`GITHUB_TOKEN` 没有 `workflows` 权限，
自动 bump 一旦改动 `.github/workflows/` 下的文件，push 会被服务端拒绝
（`refusing to allow a GitHub App to create or update workflow ... without workflows permission`）。

**推送后怎么触发构建**：`GITHUB_TOKEN` 触发的 push 事件**不会**创建新的 workflow run
（只有 `workflow_dispatch` / `repository_dispatch` 例外），所以推送后由 workflow 自己
`gh workflow run build-custom.yml` 显式触发。若在仓库里配了 `SYNC_TOKEN`
（fine-grained PAT 或 GitHub App token，需要 **Contents: r/w + Workflows: r/w**），
推送就走它，push 事件会自动触发构建，workflow 不再重复 dispatch；同时上游改动
自己 workflow 文件时也能正常同步（GITHUB_TOKEN 做不到）。

### 四道关口

| 时机 | 检查 | 拦住什么 |
|---|---|---|
| bump dae-core 前 | `Marshaller.Bytes()` 存在 | 上游重构了 wing 依赖的 API |
| bump wing 后 | 3 个 dae 导出符号存在 | 新版 wing 要的 API 当前 pin 没有 |
| push 前 | 6 处本地定制指纹 | merge 覆盖了定制内容 |
| push 后 | `Assert dae-core pin matches dae main` | pin 与 dae main 不一致 |

### 红灯含义

| 现象 | 含义 | 处理 |
|---|---|---|
| `pin stale` warning | dae 上游有更新，pin 落后 N 个 commit | 按 §5 更新 pin |
| `pin diverged` error | pin 不是 dae main 的祖先（上游 force-push/revert） | 读上游历史，人工判断 |
| `API 变更，放弃自动 bump` | wing 依赖的 dae API 消失 | 读上游 commit，评估替代方案 |
| `merge 有冲突` | 上游改了本 fork 定制过的文件 | 人工解冲突，见 §6 |

**step summary（run 页面 Summary 标签）里会写明具体缺什么。**

---

## 3. 本 fork 的本地定制（6 处）

merge 上游或 bump 时丢失任何一处，都会被指纹检查拦住。

### 3.1 Header 显示内核版本

`apps/web/src/components/Header.tsx`

在面板 Header 显示 `内核 vX`，取自 GraphQL 的 `general.dae.version`。

**为什么**：产物版本号形如 `v2.1.1-wingmain-20261014`，其中日期是**构建当天**，
同一份代码隔天重编就变一个日期 —— 版本号完全无法反映内核是否更新。
内核标签是唯一可靠的判据。

### 3.2 端点不可达时自动回退

`apps/web/src/contexts/index.tsx` + `apps/web/src/pages/Setup.tsx`

面板把 endpoint 存在 localStorage。PPPoE 重连后 WAN IP 变了，
存下来的地址就失效，导致所有请求失败。改动会在挂载时探测，
不可达则回退到当前页面来源的地址并持久化。

**为什么**：ImmortalWrt 上 PPPoE 重连是常态，手动改 endpoint 很烦。

### 3.3 `coreVersion` 词条

`apps/web/src/i18n/locales/{en,zh-Hans}.json`

给 3.1 提供中英文文案。**两个文件都要有，JSON 不能重键。**

### 3.4 `build-custom.yml`（新建）

`.github/workflows/build-custom.yml`

自建构建流水线。与官方 `release-please.yml` 的差异：

- 显式安装 clang/llvm（官方依赖 runner 预装，eBPF 那步容易挂）
- 前端从源码构建（带 3.1 的 UI 改动），不用官方 web.zip
- dae-core pin 读根目录的 `dae-core.pin`（3 个 workflow 文件之外，便于自动 bump 推送）
- 加了 pin 一致性断言（§2）

### 3.5 `release-please.yml`（已删除）

**为什么删**：fork 里 Actions 无权创建 PR，该流程必然失败：

```
GitHub Actions is not permitted to create or approve pull requests
```

已核实上游并未修复——其文件仍声明 `pull-requests: write`，无任何 fork 适配，
提交历史里最后一次改动是构建层面的。**不要恢复它。**

若上游再次改动此文件，merge 会产生 modify/delete 冲突，
解法是 `git rm` 该文件（保持删除），不是恢复。

## 4. 部署要点

目标设备：ImmortalWrt x86-64（192.168.1.1，PPPoE 出网）。

### 路径与官方不同

| | 官方 | 本设备 |
|---|---|---|
| 二进制 | `/usr/local/bin/daed` | `/usr/bin/daed` |
| geo 数据 | `/usr/share/daed/` | `/etc/daed/` |
| 服务管理 | systemd | **procd** |
| 配置 | `/etc/daed/` | `/etc/daed/` |
| 日志 | journalctl | `/var/log/daed/daed.log` |

**官方文档里的 `systemctl` 在本设备上不可用**，用 `/etc/init.d/daed`。

### 配置在 SQLite 里，不在 .dae 文件

```
/etc/daed/wing.db    ← 全部配置（节点/分组/路由/订阅）
/etc/daed/geoip.dat
/etc/daed/geosite.dat
```

面板保存时把 `.dae` 语法配置存进数据库，**不落盘成 `.dae` 文件**——
在文件系统里找不到配置文件是正常的，不是配置丢了。

### 更新二进制

```bash
# 备份
scp root@192.168.1.1:/usr/bin/daed  ~/daed.backup.$(date +%F)
scp root@192.168.1.1:/etc/daed/wing.db ~/wing.db.backup.$(date +%F)

# 替换
ssh root@192.168.1.1 '/etc/init.d/daed stop'
scp ./daed-linux-x86_64 root@192.168.1.1:/usr/bin/daed
ssh root@192.168.1.1 'chmod +x /usr/bin/daed && /etc/init.d/daed start'
```

**geo 数据不要用 bundle 里的覆盖** —— 本机有 `geo-update.env` 定时更新机制。

---

## 5. 手动 bump（断言红了时）

自动化已经处理绝大多数情况，只有红灯时才需要手动介入。

```bash
# 1. 取 dae main 最新 sha
gh api repos/daeuniverse/dae/commits/main --jq '.sha'

# 2. 确认 wing 依赖的 API 还在（bump 的前提条件）
gh api repos/daeuniverse/dae/contents/config/marshal.go --jq '.content' \
  | base64 -d | grep -E 'func \(m \*Marshaller\) Bytes\(\)'

# 3. 改根目录的 dae-core.pin（一行 40 位 sha）

# 4. 推送，触发构建
git commit -am "build(deps): bump dae-core to <短sha>"
git push
```

bump wing 同理，改 submodule 指针：

```bash
git -C wing fetch origin main
git -C wing checkout <新 sha>
git add wing && git commit -m "build(deps): bump wing" && git push
```

---

## 6. 人工解 merge 冲突

只在「上游改到了本 fork 定制过的文件」时发生。

```bash
git remote add upstream https://github.com/daeuniverse/daed.git
git fetch upstream
git checkout main
git merge upstream/main
```

冲突文件与解法：

| 文件 | 解法 |
|---|---|
| `.github/workflows/release-please.yml` | `git rm`（保持删除，见 §3.5） |
| `README.md` | 保留本 fork 版本，见 §3 |
| `apps/web/src/components/Header.tsx` | 保留 `general.dae.version` 那段 |
| `apps/web/src/contexts/index.tsx` | 保留端点回退逻辑 |
| `apps/web/src/pages/Setup.tsx` | 保留 `useEffect` 回退块 |
| `apps/web/src/i18n/locales/*.json` | 两个 `coreVersion` 都保留 |

解完跑一遍指纹校验（见 §7）确认 6 处定制都在，再 push。

---

## 7. 验证命令

```bash
# 三层指针
echo "wing    : $(gh api 'repos/szwjp/daed/contents/wing?ref=main' --jq '.sha[0:8]')"
echo "DAECORE : $(gh api 'repos/szwjp/daed/contents/dae-core.pin?ref=main' --jq '.content' | base64 -d | cut -c1-8)"
gh api repos/daeuniverse/dae/commits/main      --jq '"dae      : \(.sha[0:8])"'
gh api repos/daeuniverse/dae-wing/commits/main --jq '"dae-wing : \(.sha[0:8])"'

# 6 处定制指纹
cd <repo>
for f in "general.dae.version:apps/web/src/components/Header.tsx" \
         "coreVersion:apps/web/src/i18n/locales/zh-Hans.json" \
         "coreVersion:apps/web/src/i18n/locales/en.json" \
         "DEFAULT_ENDPOINT_URL:apps/web/src/contexts/index.tsx" \
         "endpoint unreachable:apps/web/src/pages/Setup.tsx" \
         "szwjp/daed:README.md" \
         "Assert dae-core pin:.github/workflows/build-custom.yml"; do
  k="${f%%:*}"; p="${f##*:}"
  grep -q "$k" "$p" && echo "✓ $p" || echo "✗ $p 缺失"
done
[ -f .github/workflows/release-please.yml ] && echo "✗ release-please.yml 被恢复" || echo "✓ release-please.yml 保持删除"

# 最近构建
gh run list --repo szwjp/daed --limit 5
```

---

## 8. 相关链接

- 上游 daed：https://github.com/daeuniverse/daed
- 上游 dae-wing：https://github.com/daeuniverse/dae-wing
- 上游 dae：https://github.com/daeuniverse/dae
- 社区 OpenWrt 打包方案（提供 vmlinux-btf 与 5 个 DNS/eBPF 补丁）：https://github.com/QiuSimons/luci-app-daed
- dae 内核原理：https://github.com/daeuniverse/dae/blob/main/docs/zh/user-guide

---

## License

上游 daed 为 AGPL-3.0 + MIT。本 fork 未改动任何许可证文件。
