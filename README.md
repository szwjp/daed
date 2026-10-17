# szwjp/daed

> **这是 [daeuniverse/daed](https://github.com/daeuniverse/daed) 的自维护 fork。**
> 目标：自动跟随官方 dae / dae-wing / daed 三层上游，编译出最新可用二进制并发 Release。
> 产物是这个生态里 [szwjp/luci-app-daed](https://github.com/szwjp/luci-app-daed) 的包源。
>
> **2026-10-17 上游现状**：`daeuniverse/daed` 与 `daeuniverse/dae-wing` **均已 archived**
> （最后提交分别为 2026-09-24 / 09-23），只有 `daeuniverse/dae` 还在演进。
> 「跟随上游」实际只剩 dae-core 一层会日常动作；另外两层保留检测与合并逻辑，但无新提交可同步。

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

`.github/workflows/check-upstream.yml` —— 每 6 小时运行一次（UTC 00/06/12/18），
也可手动 `workflow_dispatch`。上游没变化时只做 API 探测，不构建。

| 层 | 更新方式 | 有更新时 |
|---|---|---|
| **dae-core** | 候选 sha 交给 `build-custom.yml` 编译验证 | 编译通过并发 Release 后，由 build-custom 提交 `dae-core.pin`；失败则 pin 不动、下一轮重试 |
| **dae-wing** | `git -C wing checkout` submodule | 自动 bump + 推送（上游已 archived，实际不会再变） |
| **daed** | `git merge upstream/main` | merge 干净才自动推；冲突则停下（上游已 archived，实际不会再变） |

**为什么 pin 不在 check-upstream 里直接改**：先改 pin 再构建，一旦构建失败，仓库就停在
一个「pin 指向坏内核」的状态，而 CI 只会在构建 job 上红一次，第二天还得人工回滚。
现在改为 **pin 只在构建通过 + Release 发成功后由 build-custom 的 `pin-dae-core` job 提交**：
失败不会污染 main，下一轮调度自动重试同一个候选 sha。

**pin 为什么放在 `dae-core.pin` 这种普通文件里**：`GITHUB_TOKEN` 没有 `workflows` 权限，
自动 bump 一旦改动 `.github/workflows/` 下的文件，push 会被服务端拒绝
（`refusing to allow a GitHub App to create or update workflow ... without workflows permission`）。

**推送后怎么触发构建**：`GITHUB_TOKEN` 触发的 push 事件**不会**创建新的 workflow run
（只有 `workflow_dispatch` / `repository_dispatch` 例外），所以：
- dae-core 有更新时，由 `advance-dae-core` job 显式 `gh workflow run build-custom.yml -f dae_core=<sha>`；
- wing/daed 有更新并推送后，由对应 job 显式 `gh workflow run build-custom.yml`；
- 若在仓库里配了 `SYNC_TOKEN`（fine-grained PAT 或 GitHub App token，需要 **Contents: r/w + Workflows: r/w**），
  推送就走它，push 事件会自动触发构建，workflow 不再重复 dispatch。

### 2.1 Release 与 tag

build-custom 在 main 上构建成功后自动发 GitHub Release：

| 项 | 规则 |
|---|---|
| tag | `v<上游版本>-nightly-<YYYYMMDD>-<fork commit 前 7 位>-<dae-core 前 7 位>`，例 `v2.1.1-nightly-20261017-58fc2f0-a1b2c3d` |
| 不可变性 | tag 由「日期 + fork commit + dae-core」决定；同输入重跑幂等（回读校验后跳过，不删不重建） |
| 资产 | `daed-linux-x86_64.tar.gz`（约 34MB）+ `.sha256` |
| notes | 含本次 commit、`dae-core pin`、wing sha、bundle 版本串（下游从这行抓 pin） |

**为什么 tag 要同时带 fork commit 和 dae-core**：下游 `szwjp/luci-app-daed` 把 tag URL 和
文件 sha256 一起写进 Makefile。如果 tag 可被「先删后建」覆盖，同一天重发就会让下游写死的
hash 指向已删除的资产；而只编码 fork commit 时，同一天对同一 commit 用不同 dae-core 候选
构建会撞 tag，导致 release 内容是旧 pin、仓库 pin 却是新值。现在 tag 由完整构建输入决定，
重发只会产生新 tag，旧 tag 的资产永远有效。

### 2.2 四道关口

| 时机 | 检查 | 拦住什么 |
|---|---|---|
| 推进 dae-core 前 | 候选 sha 的 4 个 dae 导出符号存在（快速失败） | 上游重构了 wing 依赖的 API |
| 构建时 | `Assert dae-core target is dae main tip` | 构建的不是上游最新（上游又前进了） |
| 构建/merge 后 | `hack/check-fork-customizations.sh` 指纹（当前 8 项） | merge 覆盖了定制内容 |
| 构建成功后 | Release + `pin-dae-core` 才推进 pin | pin 指向一个没发布或编译失败的 sha |

失败时（任一 job 红）会自动开一个 issue 记录 run 链接；已有同名 open issue 时只追加评论。
step summary（run 页面 Summary 标签）里也会写明具体缺什么。

### 2.4 保活、自检与熔断

无人值守最怕「静默停摆」，这三项是为此加的：

| 机制 | 行为 | 为什么 |
|---|---|---|
| 保活 | 每轮 check-upstream 检查 HEAD 提交时间，超过 **25 天**没有提交就自动提交 `.github/keepalive` 并推送 | 公开仓库 60 天无活动会被 GitHub 禁用 schedule；daed/dae-wing 已归档、dae 常几周不动，靠人工提交不可靠 |
| 自检 | 每轮检查对端 `szwjp/luci-app-daed` 的 `release-sync`：workflow `state` 必须 `active`，最近一次 `schedule` 运行不超过 **30 小时**；异常则开 issue（12h 去重）。luci 侧反向检查 daed | 任一仓的 schedule 被禁用都能被另一仓发现 |
| 熔断 | dispatch 前统计 `build-custom` 最近连续失败次数，**≥3** 时暂停自动重试并打 warning | 上游永久不兼容时不至于每天无限重试；修复后手动 dispatch 或 push 一次，成功即复位 |
| 恢复收尾 | 一轮成功（skipped 不算失败）后自动关闭同名失败 issue | 不需要人工关 issue，熔断状态也随之复位 |

**关于定时触发**：schedule 依赖 GitHub 的定时器——fork 里的 scheduled workflow 需要手动启用，
且公开仓库 60 天无仓库活动会被自动禁用。发现定时不再自动跑时，去 Actions 页面重新启用即可。
（本 fork 的 build-custom 成功后会提交 dae-core.pin，属于仓库活动，有助于保活。）

### 2.3 红灯含义

| 现象 | 含义 | 处理 |
|---|---|---|
| `dae-core not at main tip` | 调度后上游又前进了，本次跳过 | 等下一轮自动重试，或手动再调度 |
| `dae API 变更，放弃自动推进` | 候选 sha 缺少 wing 依赖的符号 | 读上游 commit，评估是否同时升级 wing |
| `wing 依赖缺失，放弃自动 bump` | 当前 pin 缺少新版 wing 需要的符号 | 先升级 pin（§5） |
| `读取上游失败` | 404/网络/限流导致判断不了（不是 API 变更） | 重跑一次即可 |
| `merge 有冲突` | 上游改了本 fork 定制过的文件 | 人工解冲突，见 §6 |
| `build-custom 构建/发布失败` | 编译、geo 下载、Release 失败 | 看 run 日志；pin 未推进，下一轮自动重试 |

**step summary（run 页面 Summary 标签）里会写明具体缺什么。**

---

## 3. 本 fork 的本地定制

merge 上游或 bump 时丢失任何一处，都会被指纹检查拦住。
清单以 `hack/check-fork-customizations.sh` 为准（项数由脚本自己数，避免文档与代码对不上）。

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
- dae-core 目标可传入：`workflow_dispatch` 的 `dae_core` 输入，或读 `dae-core.pin`
- 构建成功后才发不可变 Release，并由 `pin-dae-core` job 推进 `dae-core.pin`（§2）
- 失败时 notify job 开 issue；pin 不动，下一轮调度重试

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

**首选：只触发构建，让 build-custom 自己推进 pin**（pin 只在构建成功后变）：

```bash
# 1. 取 dae main 最新 sha
SHA="$(gh api repos/daeuniverse/dae/commits/main --jq '.sha')"

# 2. 直接带着它调度构建（构建成功 → 发 Release → 自动提交 dae-core.pin）
gh workflow run build-custom.yml --repo szwjp/daed --ref main -f dae_core="$SHA"

# 3. 看结果
gh run list --repo szwjp/daed --workflow build-custom.yml --limit 3
```

**备选：手动改 pin 再 push**（会走普通 push 构建；构建失败时 pin 会留在坏值上，谨慎）：

```bash
# 1. 确认 wing 依赖的 API 还在（否则构建必失败）
gh api repos/daeuniverse/dae/contents/config/marshal.go --jq '.content' \
  | base64 -d | grep -E 'func \(m \*Marshaller\) Bytes\(\)'

# 2. 改根目录的 dae-core.pin（一行 40 位 sha）
# 3. 推送，触发构建
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

解完跑一遍指纹校验（见 §7）确认定制都在，再 push。

---

## 7. 验证命令

```bash
# 三层指针
echo "wing    : $(gh api 'repos/szwjp/daed/contents/wing?ref=main' --jq '.sha[0:8]')"
echo "DAECORE : $(gh api 'repos/szwjp/daed/contents/dae-core.pin?ref=main' --jq '.content' | base64 -d | cut -c1-8)"
gh api repos/daeuniverse/dae/commits/main      --jq '"dae      : \(.sha[0:8])"'
gh api repos/daeuniverse/dae-wing/commits/main --jq '"dae-wing : \(.sha[0:8])"'

# 自有改动指纹（与 check-upstream 用的是同一份清单，脚本自己报项数）
cd <repo> && bash hack/check-fork-customizations.sh

# 最近构建
gh run list --repo szwjp/daed --limit 5

# 最新 Release（tag 应形如 v2.1.1-nightly-YYYYMMDD-<fork7>-<dae7>，且 notes 的 pin 与 dae-core.pin 一致）
gh release view --repo szwjp/daed --json tagName,publishedAt,assets \
  --jq '"\(.tagName) \(.publishedAt) \(.assets[].name)"'
gh release view --repo szwjp/daed --json body --jq '.body' | grep -E 'commit|dae-core pin'
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
