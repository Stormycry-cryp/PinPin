# PinPin 服务端

Python 3.12+ / aiohttp。客户端只持有应用访问令牌，上游模型密钥留在服务端。服务不记录页面文本、截图、Authorization 或供应商错误正文。

## 普通网关

`gateway.py` 固定监听 `127.0.0.1:8789`，由自己的 HTTPS 入口代理：

| 路径 | 用途 |
| --- | --- |
| `GET /ping/health` | 本进程就绪检查，不验证模型或额度 |
| `POST /ping/v1/decision` | 标准 Jev 范围判断及嘴替意图/回复策略 |
| `POST /ping/v1/explanation` | DeepSeek 流式回答 |

```sh
cd backend/server
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

运行前通过本机受保护的环境配置设置 `BEATAPI_API_KEY`、`AGENT_API_KEY` 和至少 32 个非空白 ASCII 字符的 `PINPIN_ACCESS_TOKEN`；不要在命令历史或 Git 中保存真实密钥。然后运行 `.venv/bin/python gateway.py`。上游模型是源码中固定的 `jev-1.14` 和 `deepseek-v4.1-flash`，普通路由使用 Agent Plan。

`deploy/` 提供 systemd 和 Nginx 示例。`gateway.example.com`、证书、账号和目录均需按自己的服务调整。客户端要求 HTTPS；本仓库不提供可直接使用的公共模型服务。

正文上限 12 MiB，支持 identity 与 gzip；鉴权发生在读取正文和调用上游之前，模型请求不排队。服务端并发和速率配置不代表供应商账号容量。

## 独立商业订阅服务

安装时同时使用 `requirements.txt` 和 `requirements-subscriptions.txt`。`run_subscription_gateway.py --check-config` 仅读取配置，不建库或请求模型；真实 Apple 与商业 API 可用性需另行验证。

商业服务固定使用 `/pinpin/v1` 与独立端口、状态目录和 Production / Sandbox 数据库，不复用普通访问令牌。DeepSeek 使用正式商业 API，不回退到 Agent Plan。部署配置见 [deployment/README.md](deployment/README.md)，接口见[订阅协议](../../docs/subscription-api.md)。

## 本地检查

从本目录运行：

```sh
.venv/bin/python -m pip install -r requirements.txt -r requirements-subscriptions.txt
.venv/bin/python -m unittest discover -s tests -v
```

这些测试使用模拟上游和合成证书，不能代替真实购买、续费、退款、权限或公网模型验收。
