# 独立订阅服务部署模板

先为自己的应用准备 Apple App ID、月付商品、Apple 官方根证书和正式商业模型密钥。模板不包含真实凭据，也不代表服务已经上线。

1. 在独立虚拟环境同时安装 `requirements.txt` 与 `requirements-subscriptions.txt`。
2. 参考 `gateway.env.example` 配置环境文件；真实文件由部署账号保护，不进入 Git。数据库使用专用目录，Production 与 Sandbox 分开。
3. 以目标服务账号运行 `run_subscription_gateway.py --check-config`。它只做离线配置检查，不建库、不联网，不能证明购买或模型链路可用。
4. `pinpin-subscription.service` 使用独立账号和回环端口 8790。根据自己的安装位置调整路径，再验证本机健康检查。
5. 把 `nginx-commercial-locations.conf` 加到自己的 HTTPS server 中。先备份并执行 `nginx -t`，确认不会覆盖其他站点或已有 `/ping` 路由，再平滑重载。
6. 使用真实商店沙盒验证身份、购买、恢复、续费、通知、退款和用量，再验证正式商业模型请求。失败时恢复对应配置与代码版本。

隐私政策、条款和支持页面不由此模板生成。服务端模型密钥不发送给客户端，客户端也不能自行授予 Pro 额度。
