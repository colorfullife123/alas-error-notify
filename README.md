# ALAS Error Notify

面向 Docker 部署的 [AzurLaneAutoScript](https://github.com/LmeSzinc/AzurLaneAutoScript) 人工接管告警器。

它不会看到一个 `WARNING` 就叫醒你。脚本只在 ALAS 明确输出 `Request human takeover` 或 `Manual intervention required` 时，通过 MQTT 通知 Home Assistant，再由 Home Assistant 推送到手机。

## 为什么需要它

ALAS 正常自救时也可能产生这些日志：

- `WARNING`
- `Traceback`
- `AttributeError`
- `GameStuckError`
- ADB 短暂断连
- `Task call: Restart`

把它们逐行匹配成告警会产生大量误报。本项目只认“自动重试已经失败，需要人工接管”的最终标志，并对同一日志事件去重。

## 功能

- 只推送明确的人工接管事件
- 忽略 ALAS 能自行处理的中间异常
- MQTT QoS 0/1/2 可配置，默认 QoS 1
- 不使用 MQTT retain，避免 Home Assistant 重启后重放旧告警
- 同一事件只推送一次
- MQTT 失败时不写去重状态，下一轮会自动重试
- 可选复制最新 ALAS 错误截图到共享目录
- `flock` 防止多个计划任务重叠
- MQTT 密码存放在仓库外的 root-only 配置文件
- 提供 `--check` 与 `--test`

## 工作流程

```text
ALAS 日志 → 过滤可自愈异常 → 发现人工接管标志 → 去重 → MQTT → Home Assistant → 手机
```

## 环境要求

- Linux NAS/服务器
- Docker 部署的 ALAS
- Bash 4+
- `docker`、`mosquitto_pub`、`timeout`、`flock`、`sha256sum`
- Home Assistant 已连接同一个 MQTT Broker

Debian/Ubuntu 可安装 MQTT 客户端：

```bash
sudo apt update
sudo apt install -y mosquitto-clients
```

## 快速安装

```bash
git clone https://github.com/colorfullife123/alas-error-notify.git
cd alas-error-notify
sudo bash install.sh
```

安装器会：

1. 将旧 `/opt/scripts/alas_monitor.sh` 按时间戳备份；
2. 安装新版脚本；
3. 交互式创建 `/etc/alas-monitor.conf`，权限为 `600`；
4. 检测现有 root crontab，避免重复创建每 5 分钟计划任务；
5. 执行一次只读检查。

如果 `/etc/alas-monitor.conf` 已存在，安装器会保留它，不会覆盖。

## 手动安装

```bash
sudo install -d -m 755 /opt/scripts
sudo install -m 700 alas_monitor.sh /opt/scripts/alas_monitor.sh
sudo install -m 600 alas-monitor.conf.example /etc/alas-monitor.conf
sudo nano /etc/alas-monitor.conf
```

添加 root 计划任务：

```cron
*/5 * * * * /opt/scripts/alas_monitor.sh >> /var/log/alas_monitor.log 2>&1
```

## Home Assistant 自动化

将 [`home-assistant/automation.yaml`](home-assistant/automation.yaml) 导入 Home Assistant，并把：

```yaml
notify.mobile_app_your_phone
```

替换成你自己的 Companion App 通知服务名。

默认订阅：

```text
nas/alas/error
```

它必须与 `/etc/alas-monitor.conf` 中的 `MQTT_TOPIC` 一致。

## 验证

查看容器、MQTT 目标、日志窗口和最近匹配结果；不会显示 MQTT 密码：

```bash
sudo /opt/scripts/alas_monitor.sh --check
```

测试 MQTT → Home Assistant → 手机链路：

```bash
sudo /opt/scripts/alas_monitor.sh --test
```

查看计划任务日志：

```bash
sudo tail -n 100 /var/log/alas_monitor.log
```

## 关键配置

| 配置项 | 默认值 | 说明 |
|---|---:|---|
| `CONTAINER` | `alas` | ALAS Docker 容器名 |
| `MQTT_PORT` | `1883` | MQTT 端口 |
| `MQTT_TOPIC` | `nas/alas/error` | Home Assistant 订阅主题 |
| `MQTT_QOS` | `1` | 发布 QoS |
| `LOOKBACK` | `15m` | 每轮读取的 Docker 日志窗口 |
| `MANUAL_PATTERN` | 两个最终接管标志 | 触发规则 |
| `ERROR_DIR` | 空 | ALAS 错误截图源目录 |
| `IMAGE_TARGET` | 空 | 最新截图复制目标；留空关闭 |

不要把 `WARNING`、`GameStuckError`、`Traceback` 或 `AttributeError` 加进 `MANUAL_PATTERN`，否则会重新产生“ALAS 明明能自救却仍然推送”的问题。

## 安全说明

- 不要把真实 `/etc/alas-monitor.conf` 上传到 GitHub。
- `.gitignore` 已排除 `*.conf`、`.env`、日志、截图和备份文件。
- 配置文件应保持 `root:root`、权限 `600`。
- 通知消息可能包含最近的 ALAS 日志；请勿向不受信任的 MQTT Broker 发布。

## 测试

仓库内置无 Docker/MQTT 副作用的模拟测试：

```bash
bash tests/test_monitor.sh
```

它会验证：可恢复错误不告警、人工接管会告警、截图复制、事件去重和测试通知。

## 相关项目

- [AzurLaneAutoScript](https://github.com/LmeSzinc/AzurLaneAutoScript)：提供被监控的日志与人工接管状态
- [Eclipse Mosquitto](https://mosquitto.org/)：通过 `mosquitto_pub` 发布 MQTT 消息
- [Home Assistant](https://www.home-assistant.io/integrations/mqtt/)：接收 MQTT 并转发 Companion App 通知

本项目为独立实现，并非 AzurLaneAutoScript 官方组件。

## License

[MIT](LICENSE)
