# mi5x-charge-control

为 Xiaomi Mi 5X（postmarketOS、`msm8953-mainline` 内核）提供标准 Linux
`charge_behaviour` 接口和 OpenRC 电池阈值服务。

项目由两部分组成：

- `kernel/patches/`：给 `qcom-smbchg` 驱动增加
  `POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR`，支持 `auto` 和
  `inhibit-charge`。
- `openrc/`：读取电池电量，在上限停止充电，在回差下限恢复充电。

> [!WARNING]
> 刷写自定义内核有设备无法启动的风险。发布者只在源码和对象编译层面验证了
> 本项目，**尚未刷入真机验证**。刷写前必须保留可恢复启动链和原内核。

## 为什么需要内核补丁

当前 Mi 5X 的 `qcom,pmi8950-smbchg` 驱动没有暴露
`charge_control_end_threshold`，也不能直接通过标准属性停止充电。把
`qcom-smbchg-usb/online` 写为 `0` 会切断 USB 输入，而不是只停止电池充电。
本项目采用 Linux power-supply 子系统已有的标准 ABI：

```text
/sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

写入 `inhibit-charge` 会关闭 PMIC 的充电使能位，同时保留 USB 供电；写入
`auto` 会恢复充电。驱动状态在模块 probe 时初始化为 `auto`，重启后由 OpenRC
服务重新施加阈值。

## 兼容性

已验证补丁适用于以下 `msm8953-mainline/linux` 标签，两个版本中的
`qcom-smbchg.c` 和 `qcom-smbchg.h` 内容一致：

- `v7.0.9-r0`：Mi 5X 当前运行的
  `linux-postmarketos-qcom-msm8953-7.0.9-r0`
- `v7.1.3-r0`

本地验证环境为 arm64、Clang 22，使用 Mi 5X 当前内核配置编译
`drivers/power/supply/qcom-smbchg.o`。仓库 CI 会分别对两个标签应用补丁并
编译同一对象。

该项目只面向 `qcom-smbchg`。其他充电驱动应使用其已经提供的标准
`charge_behaviour` 或 `charge_control_end_threshold` 实现。

## 安装服务

先确认自定义内核已经提供目标属性，并且两种行为都可写：

```sh
cat /sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

预期输出类似：

```text
[auto] inhibit-charge
```

如果文件不存在或不包含这两个值，停止安装。不要用输入限流或直接写 PMIC
寄存器代替该接口。

安装 OpenRC 服务：

```sh
sudo make install
sudo rc-update add mi5x-charge-control default
sudo rc-service mi5x-charge-control start
```

安装过程不会覆盖已有的 `/etc/conf.d/mi5x-charge-control`。查看状态：

```sh
sudo rc-service mi5x-charge-control status
sudo mi5x-charge-control check
```

## 配置

默认在 75% 停止充电，在 60% 恢复，每 30 秒检查一次。配置位于
`/etc/conf.d/mi5x-charge-control`：

```sh
MCC_UPPER=75
MCC_LOWER=60
MCC_INTERVAL=30
MCC_BATTERY_PATH=/sys/class/power_supply/qcom-battery
MCC_CHARGER_PATH=/sys/class/power_supply/qcom-smbchg-usb
MCC_USE_SYSLOG=1
```

`MCC_UPPER` 必须大于 `MCC_LOWER`，检查间隔不能低于 5 秒。配置作为 root
shell 片段加载，因此文件必须只允许 root 修改。

手动执行一次状态转换：

```sh
sudo mi5x-charge-control once
```

紧急恢复充电：

```sh
echo auto | sudo tee /sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
sudo rc-service mi5x-charge-control stop
```

## 构建与测试

不涉及内核构建的静态检查和假 sysfs 测试：

```sh
make lint
make test
```

测试覆盖 ABI 检测、上下限转换、中间区间状态保持、幂等写入、无效配置和服务
收到 `SIGTERM` 后的干净退出。

从上游源码应用补丁并编译驱动对象需要 `git`、Clang/LLVM、Bison、Flex、bc、
OpenSSL 和 libelf 开发包：

```sh
./scripts/test-kernel-patch.sh v7.0.9-r0
./scripts/test-kernel-patch.sh v7.1.3-r0
```

脚本在临时目录克隆指定标签，先执行 `git apply --check`，再用 arm64
`defconfig` 打开驱动并编译 `qcom-smbchg.o`。它不会构建或安装完整内核。

## 真机验证清单

在刷入自定义内核后至少完成以下检查；未完成前不要把项目描述为真机已验证：

1. 启动后确认 `charge_behaviour` 显示 `[auto] inhibit-charge`。
2. 电量高于上限时启动服务，确认属性变为 `inhibit-charge`，USB 仍保持供电，
   电量不继续上升。
3. 电量低于下限时确认属性回到 `auto` 并恢复充电。
4. 覆盖中间电量、服务重启和手机重启，确认策略按预期恢复。
5. 拔插 USB、WiFi 休眠和 `s2idle` 场景下观察一次完整充放电周期。
6. 检查 `dmesg` 无 power-supply、PMIC 或充电相关错误，电池温度正常。
7. 用命令恢复 `auto`，确认不依赖服务也能正常充电。

## 安全边界

- 不修改电池浮充电压，不直接写 PMIC 寄存器。
- 不通过 `input_current_limit` 或 `online=0` 模拟充电截止。
- 不承诺降温、修复老化电池或替代硬件保护电路。
- 长期接入电源仍应关注电池温度；软件阈值只减少高电量停留时间。

## License

GPL-2.0-only，见 [LICENSE](LICENSE)。
