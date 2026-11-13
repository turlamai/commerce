# Commerce

产品家族的统一权益、独立分发与未来 Apple 内购接入，见
[商业化推进方案](docs/commercialization.md)。Apple Developer 会员提供分发能力，
不等于已有跨平台授权服务；各产品的定价与权益范围仍由产品仓库定义。

服务端改用公开的 `permit/json` 严格读取接口，不再依赖 Permit 私有模块。
源码构建要求 Permit `0.2.1` 或更新版本；CI 与 Docker 固定同一源码提交。
本次改动不发布新版本。

**所有产品，共用一份商业真相——支付事件进入，签名产品权益输出。**

[![CI](https://github.com/turlamai/commerce/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/commerce/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE) ![Stage](https://img.shields.io/badge/stage-M3%20Subs-C15F3C)

[English](README.md) · **中文**

Commerce 是面向独立软件产品家族的渠道中立商业管理面。所有产品通过同一处
创建结账、接收并审计支付事件、投影订单与订阅状态，再把商业结果变成由
[Permit](https://github.com/turlamai/permit) 签发的产品权益。

Commerce 不是支付机构、Merchant of Record、税务引擎、CRM 或 DRM。
Pancake、ZPAY、应用商店与未来渠道负责资金流转；Permit 负责可在本地验证的
签名权益；Commerce 只拥有二者之间可持久化、可重放、可审计的编排过程。

**渠道中立。事件驱动。权益优先。**

## 使用入口

仅当产品需要持久的支付到权益编排时使用 Commerce。它是一个无界面服务，具有明确渠道与 Permit 签发边界；不是支付机构、MoR、身份系统，也不证明商户准入。

[使用选择、成熟度、升级与支持](docs/USING.zh-CN.md) · [English](docs/USING.md)

## 快速开始

当前版本已经包含纯事件核心、重放冲突防护、订单投影、权益意图、渠道边界、
持久 SQLite 原始事件 journal、Pancake 原始字节验签与一次性订单主动查验、测试
和一条完整的购买演示；订单投影与签发 outbox 已能同事务持久化，Offer policy
已能生成版本固定、完整且经过 Permit 校验的权益快照，签发 outbox 也已具备
owner 安全的租约状态机和事务型 lineage 写入器，显式 issuer worker 已能认领、
签名、把签名信封落为持久凭证证据，交给客户一枚一次性 claim token，并提供
退款与运营重放面。

Commerce 尚未发布到 Racket 官方包目录，请从本仓库安装：

```bash
git clone https://github.com/turlamai/commerce.git
cd commerce
raco pkg install --auto --name commerce --link "$PWD"

racket examples/first-purchase.rkt
```

预期输出：

```text
order ord_demo_001: paid
rights intent: grant taskly-pro-lifetime to customer-demo
duplicate webhook: ignored
```

第一次接触项目请继续阅读 **[快速上手](docs/getting-started.zh-CN.md)**。
[文档导航](docs/README.md) 为每类架构和运维问题指定唯一的规范入口。

## 为什么需要 Commerce？

单个产品可以在一个下午接好一次支付；产品家族不能在每个应用里重复实现
支付验签、重试、退款、订阅续期、凭证找回与许可证签发。

Commerce 建立一条统一边界：

- **产品只理解 Offer 与权益** —— 永远不内嵌渠道 API 密钥或签发私钥。
- **渠道只陈述支付事实** —— 每个 adapter 验证原生协议，再输出同一组精简事件。
- **Permit 只表达授权** —— Commerce 请求签发完整权益快照，应用在本地验证。
- **每次转换都可审计** —— 原始事件不可变保存，重复投递无害，冲突重放关闭失败，
  签发走显式 outbox，不在 Webhook 请求里偷偷完成。

## 家族中的位置

```text
                         产品
                    /      |       \
              Rivet/Glaze Permit  Commerce client
                    UI     本地验权       |
                                         v
                                 Commerce service
                              /          |          \
                       Pancake         ZPAY       应用商店
                              \          |          /
                                  已验证支付事件
                                         |
                                      权益意图
                                         |
                                  Permit issuer
                                         |
                              签名 Permit credential
```

依赖方向不可倒置：

```text
product  -> Rivet 或 Glaze
product  -> Permit
product  -> Commerce client       （需要在线商业能力时才使用）

Commerce service -> 支付渠道
Commerce service -> Permit issuer

Rivet / Glaze / Keel -X-> Commerce
Permit               -X-> Commerce
```

本仓边界见[架构](docs/architecture.md)与[家族集成](docs/family-integration.md)；
[五仓家族架构](https://github.com/turlamai/keel/blob/main/docs/family-architecture.md)
是跨仓依赖、职责与发布顺序的唯一权威来源。

## 核心词汇

| 概念 | 含义 |
| --- | --- |
| Product | 稳定的软件身份，例如 `taskly` |
| Offer | 用户实际购买的方案，例如 `taskly-pro-lifetime` |
| Provider mapping | 实现 Offer 的 Pancake、ZPAY 或商店标识 |
| Payment event | 渠道验证后产生的不可变支付事实 |
| Order projection | Commerce 保存的最小商业状态投影 |
| Rights intent | 授予、续期、替换或收回权益的可审计请求 |
| Issuance | 最终 Permit credential 及其交付状态 |

Commerce 不复制支付渠道的完整商品目录或客户库。渠道对象仍是支付事实源；
Commerce 只保存确定性编排需要的标识、投影和审计证据。

## 公共模块

```racket
(require commerce)           ; 纯领域模型与状态转换
(require commerce/provider)  ; 服务端渠道 adapter 边界
(require commerce/journal)   ; 持久事件接收契约
(require commerce/storage)   ; 持久投影/outbox 操作
(require commerce/storage/sqlite) ; SQLite 服务存储后端
(require commerce/pancake)   ; Pancake 鉴权与主动订单证明
(require commerce/permit)    ; 经审阅的 Offer policy 到 Permit 快照
(require commerce/issuer)    ; 显式签发 worker：认领、签名、交付
(require commerce/admission) ; 渠道准入记录，未准入不结账
(require commerce/evidence)  ; 签名前独立复核证据
(require commerce/operator)  ; 运营 find/explain/redrive 面
(require commerce/log)       ; 结构化脱敏事件日志
(require commerce/health)    ; readiness 快照与卡死工作告警
(require commerce/server)    ; HTTP webhook 边界与 claim 门户
(require commerce/reconcile) ; 有界渠道事实对账
(require commerce/backup)    ; 一致性快照与备份校验
(require commerce/retention) ; 回收过期的未领取 claim
(require commerce/purchase-progress) ; 产品侧购买进度读取（已鉴权）
(require commerce/checkout-http) ; 准入后的仅一次托管结账传输
```

开发阶段的托管服务家族（`commerce/hosted-registry`、
`commerce/hosted-auth`、`commerce/hosted-admission`、
`commerce/hosted-entitlement`、`commerce/hosted-proof`、
`commerce/hosted-http`）与支付宝 adapter 候选（`commerce/alipay`）
由 `docs/` 下的设计文档承载，不冻结在本清单里。

默认的 `commerce` facade 不暴露渠道密钥、原始 Webhook 接收、网络监听、数据库
或 Permit 签名能力。这些能力必须从明确的服务端模块显式引入。

## 托管权益防回滚

新增[托管权益消费者持久化版本记录](docs/hosted-consumer-watermarks.md)：经 Permit
验签的最新授权或撤回修订会写入受控 SQLite，拒绝旧版本回放、不同权益谱系替换。
撤回凭证始终代表拒绝授权，并非付款成功标志。目前是 Racket 端参考实现，
尚未接入 Publy 的 TypeScript 服务端，也不代表线上支付可用。

## 购买、签发与恢复状态

新增[产品后端受控购买进度读取](docs/purchase-progress.md)，可区分等待支付、
支付处理中、权益签发处理中、凭证已记录、退款处理中与已退款。此接口不能作为
软件授权依据，不包含用户信息或领取 Token；实际凭证导入由产品端确认。

运营人员可执行 `raco commerce doctor <database>` 进行**真正只读**的健康诊断：
使用 SQLite 只读连接检查现有 schema v8 数据库，输出脱敏的 JSON 就绪状态。
发现告警或不兼容的旧版数据库时返回非零退出码；不会创建数据库、自动迁移、
新增索引或修复数据。需要迁移时必须按正式运维手册操作。

## 支付宝 Vibe Pay（待验收接入）

**Publy 的服务端结账试验接口（Commerce #51）：** 新增可选的
`commerce/alipay/checkout-coordinator` 与 `commerce/alipay/checkout-http`，
只接受经过服务间认证、带持久化防重放 nonce 的请求，由 Commerce 侧确定
经审阅的 Offer 和 CNY 精确价格。相同请求安全重试复用同一不可变订单，
返回的是支付宝签名参数，**不是已付款或已获得 Permit 权益**的证明。
规范见 [ADR-0023](docs/decisions/0023-alipay-checkout-coordinator.md) 和
[ADR-0024](docs/decisions/0024-alipay-checkout-transport.md)。
目前仅供本地回环联调，不能当作公网支付接口；上线前还必须部署持久化防重放与
结账声明存储、隔离签名权限、核验真实商户准入和全链路支付领取证据。
一次性预付服务期不意味着自动续费。

已增加可选的运营侧退款持久化状态机：第一次退款发送前记录“结果未知”，重启或
超时后禁止自动再次发起退款；只有经过验签的完整退款查询结果才能登记权益撤回。
运营者可明确配置支付宝客户端，通过授权的持久化流程单次发起退款；
HTTP 返回本身不能确认退款。真实沙箱退款、商户准入和正式上线仍需验收。


支付宝运营侧结账示例已增加**拒绝优先**的商户准入配置检查：必须由运营方私下
确认商户资质、交易方式、币种、Offer 原价、上下限和成本资料，才能生成订单。
仓库中的 JSON 模板故意设置为无效，不能直接启用收款；配置文件本身也不代表
支付机构已审批。真实商户与交易验收仍由 #5/#4 独立把关。


已新增[支付宝 Vibe Pay 基础收款接入说明](docs/alipay-vibe-pay.md)：
Racket 服务端签名下单、主动查单验签、严格异步通知及 SQLite
日志入库。**完整 CI、商户资质与实际交易验证尚未完成**，
不得据此宣称已能正式收款，也不需要 Node/npm 运行环境。

## 当前状态

已经实现：

- 精确整数最小货币单位与稳定 Offer 身份；
- 已验证的规范支付事件；
- 渠道事件幂等与冲突重放拒绝；
- 能正确处理“退款先于支付通知到达”的订单投影；
- 确定性的 `grant` / `withdraw` 权益意图；
- 渠道 adapter 契约与 mock 购买演示；
- 持久 SQLite 原始事件 journal，包含摘要复核、精确重放、冲突拒绝和数据库级
  不可变保护；
- SQLite schema v8，包含 v1–v7 原位迁移、确定性 journal 投影、订单与签发
  outbox 的原子写入，以及只追加且 revision 连续的 entitlement lineage 证据；
- Pancake RSA-SHA256 原始字节验签，包含显式环境密钥、有限重放窗口、mode 绑定
  和脱敏的类型化错误；
- 带商户签名的 Pancake GraphQL 查单：在构造规范支付事件前，将已完成的一次性
  订单与商店、环境、外部结账引用、商品、成功支付、精确币种/金额、稳定主体和
  Offer 全部绑定；
- 显式 `commerce/permit` adapter：复用 Permit 校验版本固定的 Offer policy，
  生成完整 revision 0 grant 或在签发时到期的 withdrawal successor 及其精确字节；
- owner 安全的签发 outbox 租约状态机：租约互斥、attempts 可观察、过期租约可
  回收、owner 校验的完成与类型化释放；完成动作在同一个事务内追加 lineage 根
  加 revision 0（或恰好一个 successor）并完结 outbox 行，重复完成会对账回
  已记录的 revision；
- 显式 `commerce/issuer` 签发 worker：确定性的 lineage/credential id、快照
  准备、在 claim 事务之外对记录字节做确定性 Ed25519 签名、签名前以类型化
  错误拒绝确定性死局、瞬态失败有限退避、崩溃对账；
- 一次性 claim 交付：只追加的签名凭证证据、仅存摘要的随机 claim token、
  ready/claimed/expired 显式交付状态与幂等通知标记，以及永不推进 lineage
  revision 的类型化 claim 兑换；
- 退款与运营重放面：脱敏的订单解释、outbox 枚举，以及只复用不可变
  journal、绝不改投影行、绝不回退已完成工作的有界 redrive；
- 结构化、构造即脱敏的事件日志，带运营关联 id（journal、投影、租约、
  claim 各转换点）；
- 只读 readiness 快照与类型化卡死告警，`raco commerce` 运营 CLI
  （find、explain、redrive）作为受支持的无头工作流；
- 运维证据工具：一致性数据库快照、验证完整性与计数的恢复演练、过期
  claim 的退休，以及证明同一 lineage 可携带不同 key id 签名的轮换演练；
- HTTP webhook 边界与 claim 门户：对精确字节验签、解析持久 checkout
  期望（schema v6，只追加 binding）、主动查单、幂等 journal、完备状态码
  映射；门户经 HTTP 兑换一次性 claim（未知/重用/过期分别 404/409/410）；
- schema v8 运营审计（只追加的 action/operator/reason 证据）与有界
  凭证补发（同一凭证换发新 token,带审计）；
- 有界渠道对账：签名读取订单事实与投影比对，输出类型化差异，绝不改动
  持久状态；
- 订阅语义：渠道上报的 paid-through 窗口、在付费窗口到期的幂等键续订
  revision，以及周期末失效的取消 successor（ADR-0014）；
- 一条覆盖真实协议边界的可运行端到端旅程（`examples/full-journey.rkt`）
  与运营手册（[docs/runbook.md](docs/runbook.md)）；
- 双语入口文档、规范架构与 CI 门禁。

仍需外部集成与发布证据：

- 真实渠道沙箱凭据，以及 checkout 到领取凭证的完整证据；
- 面向渠道 API 的 checkout 创建（持久 binding 已实现；checkout UI 属产品侧）；
- 邮件等外发交付渠道（HTTP 凭证领取门户已实现）；
- ZPAY、应用商店等 adapter，仅按真实产品需求引入；
- 图形运营后台，仅在现有运营 CLI 不足时建设；
- 生产部署和运行 canary。这里不声明支付渠道认证或生产就绪。

上述 HTTP 边界、领取门户、运营重放/审计、订阅投影已是实现面，不再列为 TODO；
本地/fixture 覆盖与真实渠道集成证据分别记录。gptp-studio 的
「根据支付时间计算维护更新窗」已由[合并的 PR #2](https://github.com/turlamai/commerce/pull/2)
实现并关闭 [issue #1](https://github.com/turlamai/commerce/issues/1)，但这仍是
夹具验证，不是真实渠道订单。下一步必须验证商户准入、可信签发和真实购买与领取，
以 [ROADMAP.md](ROADMAP.md) 和[发布证据清单](docs/release-checklist.md)
作为放行依据。

## 部署

`examples/service.rkt` 支持 `COMMERCE_ROLE=edge|issuer|all`。建议以不同的
操作系统身份运行 HTTP Edge（不加载 Permit 签名私钥）与 Issuer（不开放 HTTP
监听），共用 SQLite 存储；`all` 仅保留本地合并演练。具体配置参考
[部署指南](deploy/README.md)，未解决的共享数据库写权限风险详见
[ADR-0020](docs/decisions/0020-split-service-roles.md)。**进程拆分不等于签发授权
已完全隔离，更不代表具备真实付款上线证据。**`/readyz` 提供就绪状态，
崩溃后仍依赖持久化重试收敛。

## 安全问题与发布状态

安全漏洞请遵循 [SECURITY.md](SECURITY.md) 的**私密报告流程**，
不要在公开 Issue 中粘贴可利用的细节或密钥。
[发布证据清单](docs/release-checklist.md) 明确列出未满足的商户准入、
签发信任及真实购买门禁；模拟购买成功不能代表生产就绪。

## 开发

```bash
raco pkg install --auto --no-docs --name commerce --link "$PWD"
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/storage.rkt commerce/storage/sqlite.rkt commerce/pancake.rkt \
  commerce/permit.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

修改边界前先读 [AGENTS.md](AGENTS.md) 和[架构](docs/architecture.md)。公共 API
变更必须同时提交测试、受影响的中英文入口文档和对应规范文档。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
