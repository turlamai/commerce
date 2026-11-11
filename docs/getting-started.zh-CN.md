# 快速上手

[English](getting-started.md) · **简体中文**

本教程让第一次接触项目的人从一套空白 Racket 环境走到一笔可审计的购买状态
转换。这里刻意使用 mock 边界：不需要注册账号、配置密钥、访问网络或真的付款。

## 1. 环境要求

- Racket CS 9.0 或更高版本
- Git

## 2. 安装源码链接包

```bash
git clone https://github.com/turlamai/commerce.git
cd commerce
raco pkg install --auto --no-docs --name commerce --link "$PWD"
```

普通产品安全地从默认 facade 开始：

```racket
(require commerce)
```

只有服务端渠道 adapter 显式引入：

```racket
(require commerce/provider)
```

需要持久接收已认证事件的服务再显式引入：

```racket
(require commerce/journal
         commerce/storage
         commerce/storage/sqlite)
```

Pancake 边缘模块在显式环境中认证原始请求字节：

```racket
(require commerce/pancake)

(define verified
  (verify-pancake-webhook raw-body signature-header
                          #:environment 'test))
```

`verified` 仍是渠道原生证据，不是规范支付事件。服务随后提供服务端保存的结账
绑定与商户凭据：

```racket
(define merchant
  (make-pancake-merchant-client
   "MER_yourMerchant"
   (getenv "PANCAKE_MERCHANT_PRIVATE_KEY")
   #:environment 'test))

(define binding
  (pancake-order-binding
   "random-checkout-reference" ; 创建结账时保存
   "PROD_providerProduct"
   "taskly-pro-lifetime"
   "opaque-stable-subject"
   (money "USD" 2900)
   2))                         ; 配置明确的 ISO 4217 小数位

(define canonical-event
  (verify-pancake-onetime-order merchant verified binding))
```

主动证明要求订单已完成，且 Webhook 指向的支付成功；环境、商店、外部引用、商品、
币种和精确金额必须全部一致。私钥只由部署注入，绝不提交。外部引用在服务端存储
中解析到 Offer 与稳定主体；它不是邮箱、主体 id 或客户端提供的声明。

持久接收与投影刻意分成两个操作：

```racket
(define storage (open-sqlite-commerce-storage database-path))

;; 这个 commit 成功后即可向渠道确认。
(journal-accept! storage raw-body canonical-event
                 #:received-at receive-time)

;; 在 Webhook 请求之外运行；#f 表示没有待处理序列。
(let project-pending ()
  (when (storage-project-next! storage #:processed-at (current-seconds))
    (project-pending)))
```

每次 projector 调用把订单、新产生的签发工作与来源序列标记一起提交。outbox 行
仍保持 `pending`；当前版本不会调用 Permit 或交付 credential。

独立的 Permit adapter 只准备完整权益快照，不做签名：

```racket
(require commerce/permit)

(define pro-policy
  (make-permit-entitlement-policy
   "taskly-pro-v1" 1
   #:subject-type 'person
   #:grants
   (list (make-permit-grant-policy
          #:products '("taskly")
          #:edition "pro"))))

(define policy-catalog
  (make-permit-policy-catalog (list configured-offer)
                              (list pro-policy)))

(define snapshot-request
  (prepare-permit-snapshot
   policy-catalog grant-intent
   #:issuer "com.example"
   #:credential-id stable-credential-id
   #:entitlement-id stable-entitlement-id
   #:issued-at "2026-10-17T03:00:00Z"))
```

Offer 固定引用不可变 policy id。结果包含经过 Permit 校验的 payload，以及未来
signer 必须直接消费的精确字节。withdrawal 还必须提供上一份完整 snapshot；
这里不会接触私钥或 signer。

## 3. 跑通第一笔购买

```bash
racket examples/first-purchase.rkt
```

演示假设 mock adapter 已经完成渠道原生鉴权，然后把支付事件应用到不可变状态。
第一次转换产生一个 `grant` 权益意图；同一渠道事件再次投递时会被正常确认，
不会重复产生权益。

## 4. 修改行为前先读测试

```bash
raco test commerce-test/core-test.rkt commerce-test/journal-test.rkt \
  commerce-test/storage-test.rkt commerce-test/pancake-test.rkt \
  commerce-test/permit-test.rkt
```

测试直接回答首批最难的问题：

- 渠道重复投递同一个 Webhook 怎么办？
- 同一个 event id 被不同内容重用怎么办？
- 退款通知比支付成功更早到达怎么办？
- 两条成功通知为什么不会签发两次？
- 同一个订单的金额或 Offer 被改动时怎么办？
- 什么证据能证明确认结果可以跨服务重启保留？
- 实际写出的数据库行是什么，普通 SQL 能否篡改它？
- Pancake 到底签了哪些原始字节，过期、跨环境或有歧义的已签请求如何关闭失败？
- 商户查单请求具体签了什么，主动订单中任一字段被替换时为何无法产生规范事件？
- 哪些数据库行能证明订单投影与签发工作一起提交，注入崩溃后又会留下什么？
- policy 版本固定、Offer 删除、无效 policy 与 lineage 不匹配如何在 signer
  接触字节前关闭失败？

## 5. 理解边界

按顺序阅读：

1. [核心概念](concepts.md)
2. [架构](architecture.md)
3. [渠道契约](provider-contract.md)
4. [Permit 集成](permit-integration.md)
5. [安全](security.md)

不要拿渠道 SDK 的 happy path 示例直接开写 adapter。先在渠道契约中明确鉴权方式、
重试行为、主动查单 API、退款语义、测试模式和固定测试证据。

## 6. 跑完整门禁

```bash
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/storage.rkt commerce/storage/sqlite.rkt commerce/pancake.rkt \
  commerce/permit.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

首个真实渠道是 Pancake。签名协议一致性、一次性订单主动查验、journal /
投影 / outbox 持久处理、Permit snapshot policy 映射、租约守护的签发、
确定性签名与一次性 claim 交付均已实现。退款/运营重放工具与真实 sandbox
证据仍是 [ROADMAP.md](../ROADMAP.md) 中彼此独立的 M1 门禁。


[升级、成熟度与支持](USING.zh-CN.md)。
