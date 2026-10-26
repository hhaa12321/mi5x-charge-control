# 2026-10-26 真机验证

## 测试环境

- 设备：Xiaomi Mi 5X / Mi A1，设备树 `xiaomi,tissot`，SoC `msm8953`
- 系统：postmarketOS v26.06，OpenRC
- 原内核包：`linux-postmarketos-qcom-msm8953-7.0.9-r0`
- 内核源码：`msm8953-mainline/linux` 标签 `v7.0.9-r0`，commit
  `5be94b504b80d032481b90d533ee350ee13850f2`
- 编译器：Ubuntu Clang/LLD 22.1.2，arm64
- 充电驱动：`qcom,pmi8950-smbchg`，电源设备
  `qcom-smbchg-usb`
- 电池：`qcom-battery`，健康状态 `Good`

构建使用设备当前生效的完整内核配置。补丁在编译阶段通过了
`v7.0.9-r0` 和 `v7.1.3-r0` 的 `qcom-smbchg.o` 对象编译以及仓库 CI。

## 启动与回退

原内核和原 `extlinux.conf` 在安装前完成备份及 SHA-256 校验。设备上的
`/boot/vmlinuz` 没有覆盖，自定义镜像使用独立文件 `/boot/vmlinuz.custom`；
启动菜单同时保留 `custom` 和 `stock`。

关键 SHA-256：

```text
stock vmlinuz       3998ceaae9b40b0c108d3b0ca83fc8ea937b676cd550453cdc6c07b14ee2822a
stock extlinux.conf a0ec1be7cbb2fe575cb165e78916f2ef01f64c346daeb6fa80b92936cbd5e963
custom vmlinuz      16cf2edc0978bce8962a0cd2cc9d24391b740023512d282847a84e94d31c430e
custom System.map   a2195984e0b8e19e25cd2f1a10660f3907651d9c6ee9e0e4c7030f656a9d26b6
custom config       365ce1aa38929ef11fead35dbc580be20e3cb9034477b98e16b7867c04e2f898
custom extlinux     dfcdaa162ef524fced5f7654e2fddc60f551677da288f736ff679500a046d3c8
```

上电后 `/proc/version` 报告：

```text
Linux version 7.0.9-msm8953 #1-postmarketos-qcom-msm8953 SMP PREEMPT Mon Oct 26 14:42:12 CST
```

重启后 uptime 归零，`/boot/vmlinuz.custom` 的实际 SHA-256 与构建产物一致。

## 充电行为

新内核暴露标准接口：

```text
/sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

初始值为 `[auto] inhibit-charge`。在电池 99%、USB 输入在线时手动切换：

- 写入 `inhibit-charge` 前：`status=Charging`、`current_now=-74462`、
  `usb online=1`。
- 写入并等待 12 秒后：属性为 `auto [inhibit-charge]`、
  `current_now=-610`、`usb online=1`。
- 写回 `auto` 后：属性恢复 `[auto] inhibit-charge`，随后观察到
  `current_now=-13732`、`usb online=1`。

99% 附近存在满电涓流和采样波动，因此这些瞬时值不替代一次完整充放电周期。
它们用于确认属性写入被驱动接受，且停止充电时 USB 输入没有被切断。

为了在不修改服务配置的情况下验证上下限逻辑，测试用临时电池 capacity 路径
配合真实 charger sysfs：80% 时服务写入 `inhibit-charge`，55% 时写回 `auto`，
两次均确认 USB 在线。这个测试验证了服务集成，不声称真实电池已经放电至 55%。

## OpenRC 服务

首次启动暴露了一个真实兼容问题：sysfs 输出
`auto [inhibit-charge]`，原解析器只识别以 `[inhibit-charge]` 开头的格式，
导致服务完成第一次转换后在下一轮退出。修复后解析器识别任意位置的方括号选中值，
假 sysfs 测试也改用真实输出顺序。

修复版在真机上的结果：

- 99% 电量下启动后立即进入 `inhibit-charge`，USB 仍为 `online=1`。
- 连续运行 74 秒、经历至少两个 30 秒采样周期，OpenRC respawn 计数保持 `0`。
- 手机再次重启后服务随 default 运行级自动启动，属性恢复为
  `auto [inhibit-charge]`。
- 手动重启服务并等待 36 秒，服务保持 `started`，respawn 计数为 `0`。
- `dmesg` 未发现 `smbchg`、PMIC、电池、thermal、OOM、panic 或 I/O error
  相关错误；CPU/PMIC 温度约 35.1-38.2 摄氏度，电池热区约 33.7 摄氏度。

## 尚未覆盖

- 真实电池从 75% 以上放电到 60% 以下的完整恢复过程。
- 连续数日的阈值保持、满电静置和电池温度趋势。
- USB 反复拔插、WiFi 休眠、`s2idle` 和异常掉电后的恢复。
- stock 内核的物理启动菜单回退演练；当前 stock 镜像和启动项均保留且哈希已核对。

OpenRC 服务当前将 stdout/stderr 定向到 `/dev/null`，配置启用的 syslog 在测试
系统上未运行。服务运行状态和 sysfs 结果可直接检查，但状态转换日志不会持久化；
这不影响阈值控制，后续部署若需要审计日志应先启用 syslog 或增加日志轮转。
