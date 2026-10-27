# Mac App Store 订阅接口约定

本文件描述源码中的接口；公开快照不提供已部署的订阅服务。月付产品 ID 为 `com.pointout.app.pro.monthly`，数量规则为免费 20 / Pro 1000；实际价格从 StoreKit 商品读取。

## 身份

商店版本使用经过服务端 Apple 签名验证的 `AppTransaction.appTransactionID` 建立稳定用量身份，无需额外注册邮箱或密码。Apple 文档说明此 ID 在相同 Apple 账号与 App 下跨设备、重新下载及退款保持稳定，也适用于未购买内购的用户。客户端上送签名 JWS，服务端自行验证 bundle、环境与 Apple App ID；不能只接受客户端提交的 ID。

旧系统若拿不到非空 ID，不随机创建新的免费身份，提示刷新购买信息并重试。真实商店验证尚待完成。Windows 的现有私测连接不改；Windows 订阅身份关联另行验收。

## 端点

商业服务基地址为 `/pinpin/v1`，现有私测 `/ping/v1` 继续保留。所有时间用 UTC ISO 8601，所有错误体为 `{"error":{"code":"...","message":"..."}}`。生产和审核 Sandbox 使用同一个商业地址，由服务端按签名所属环境隔离。

### POST /subscription/session

请求：`{"signed_app_transaction":"<JWS>"}`。

服务端验证成功后返回 `access_token`、`expires_at`、`app_account_token`。令牌使用随机高熵值、数据库只存摘要；客户端存在 Keychain。`app_account_token` 是服务端为当前身份保存的固定 UUID，供 StoreKit 购买绑定。不得将原始 JWS 或访问令牌写入日志。

### GET /subscription/state

要求会话 Bearer。返回 `plan`（free/pro）、`period_start`、`period_end`、`limit`、`committed`、`reserved`、`remaining`。这是最终权益来源；客户端完成本地 StoreKit 验签不能自行永久开通服务端额度。

### POST /subscription/transaction

要求会话 Bearer。请求：`{"signed_transaction":"<JWS>"}`。

验证 Apple 签名、环境、bundle、产品 ID、实际起止时间、`appTransactionId` 与会话身份相同。若交易携带 `appAccountToken`，还须与服务端绑定相同；缺失时仍须通过已验证的 appTransactionId 和 originalTransactionId 归属确认，不能信任客户端补填。记录 originalTransactionId 归属，不能被其他身份重新绑定。将实际交易映射到内部账本，重复恢复不增加额度。返回与 state 相同的权益快照。返回确认前客户端不得 finish 交易，也不能显示服务已开通。

### POST /subscription/apple-notifications

请求 Apple V2 的 `{"signedPayload":"<JWS>"}`，不使用客户端会话。外层通知及内层交易均须验证；不认识的产品或测试通知不授予权益。已有归属的续费、撤销、退款按已验证时间更新，重复通知幂等。没有映射的交易不凭通知任意创建用户。

### POST /subscription/actions/cancel

要求既有会话 Bearer。请求 `{"action_id":"<UUID>"}`，取消当前身份尚未完成的预约，返回 `action_id` 与当前 `state`。已取消的操作幂等，已完成操作保留已结算状态；未知、其他用户或其他环境的 ID 都返回 404，不创建新预约。

客户端仅在 AI 操作失败或取消时有界清理，不为清理创建或刷新会话。未收到答复时仍由租约到期释放。Jev 返回不适用而不继续回答，也需要释放预约。

## 客户端生命周期

- 启动仅建立一个 `Transaction.updates` 监听；商品按需加载，关闭面板不重复监听。
- 购买必须使用 StoreKit 的真实商品与服务端 `app_account_token`。处理用户取消、待批准、交易失败和服务器暂时不可用。
- 恢复购买只在用户操作时调用 `AppStore.sync()`，随后同步已验证交易。启动可读取 currentEntitlements，不自动反复要求登录。
- 最终权益与余量读取服务器，过期信息不作无限期授权。服务器确认后再 finish，网络失败保留待同步交易。
- 流式输出与模型请求继续保持既有内容和质量；用量按一次用户操作结算，Jev 与回答模型不能重复扣两次。

## 验证边界

管理员显式配置 Production 与 Sandbox 两个独立数据库和 Apple 验签器，供同一二进制的正式用户、TestFlight 与 App Review 使用。JWS 中的环境提示仅选择候选，随后必须完成对应环境的签名验证；失败不切换验证器重试。会话、交易、通知、额度与操作阶段保持同环境，不能相互借用。

Xcode/LocalTesting 的无签名数据只能进入明确的离线测试适配器，不能由网络请求切换验证模式。使用 Apple 官方 App Store Server Library 的已修复版本，两个真实环境都启用在线证书状态检查。Production 缺少真实 Apple App ID 时拒绝启动。

来源：[appTransactionID](https://developer.apple.com/documentation/storekit/apptransaction/apptransactionid)、[Apple 官方服务器库](https://github.com/apple/app-store-server-library-python)。
