# 生产包安装

从本仓 GitHub Releases 下载固定版本的源码包、`.CHECKSUM`、`SHA256SUMS` 和 `release.json`，先执行 `sha256sum -c SHA256SUMS`。发布记录包含源码提交和构建运行时；Racket 原生包校验使用 SHA-1，发布完整性另外使用 SHA-256。

每个服务使用独立、带版本的 Racket 安装。使用标准包管理器 `raco pkg install --installation --copy --auto --batch --no-docs --name commerce /verified/commerce-VERSION.zip`；Commerce 先安装经过核对的 Permit 发布包。生产环境禁止源码链接、浮动分支、开发者家目录以及用 `--force` 掩盖包冲突。不要复用其他应用的包作用域。运行时和包由 root 管理并只读，服务使用独立普通账户，`PLTUSERHOME` 不指向 root 家目录。

配置和密钥位于 `/etc/<service>`，数据位于 `/var/lib/<service>`，持久服务单元位于 `/etc/systemd/system`。每次把新版本装进新目录，核对包来源、导入和依赖校验记录后才切换活动链接。保留上一运行时和一致性数据库备份；回滚程序不能撤销数据库迁移，需要时恢复经过演练的对应快照。

发布流程安装并测试实际源码归档，并要求标签版本匹配且同一提交的 main CI 全绿。库发布不代表商户准入、支付开通或产品实机验收；既有商业和安全门禁继续生效。本地贡献者仍可使用源码链接。

[English](production-install.md)

安装后，以服务账户从可读的工作目录运行 `raco commerce --help`，实际验证命令注册和执行入口，而不只验证模块导入。可复用 CLI 也支持 Racket 标准模块入口 `racket -l commerce/operator/cli -- --help`。0.1.3 修复此前多集合归档缺失的集合级命令注册。
