# mi5x-charge-control

为 Xiaomi Mi 5X（postmarketOS、`msm8953-mainline` 内核）提供标准 Linux
`charge_behaviour` 接口和 OpenRC 电池阈值服务。

项目由两部分组成：

- `kernel/patches/`：给 `qcom-smbchg` 驱动增加
  `POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR`，支持 `auto` 和
  `inhibit-charge`。
- `openrc/`：读取电池电量，在上限停止充电，在回差下限恢复充电。

> [!WARNING]
> 刷写自定义内核有设备无法启动的风险。本项目已在 Xiaomi Mi 5X / Mi A1
> (`tissot`) 的 postmarketOS v26.06、`7.0.9-msm8953` 内核上完成真机验证，
> 但其他内核版本和设备仍需自行验证。刷写前必须保留可恢复启动链和原内核。
> 实测记录见 [真机验证](docs/hardware-validation-2026-10-26.md)。

postmarketOS 更新内核时会重新生成 `extlinux.conf`。仓库提供的安装脚本会把
补丁内核设为固定默认项、保留 stock 回退项，并关闭该自动生成，避免更新后悄悄
回到没有 `charge_behaviour` 的原版内核。

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

先安装并验证补丁内核启动项。下面使用当前已验证镜像的 SHA-256；重新构建内核后
必须改为新构建记录中的哈希：

```sh
sudo ./scripts/install-kernel-boot-entry.sh \
  16cf2edc0978bce8962a0cd2cc9d24391b740023512d282847a84e94d31c430e
sudo reboot
```

重启后确认自定义内核已经提供目标属性，并且两种行为都可写：

```sh
cat /sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

预期输出类似（方括号表示当前选中的行为）：

```text
[auto] inhibit-charge
```

服务在电量高于上限后会把当前值切换为：

```text
auto [inhibit-charge]
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

## 回退

自定义内核安装为 `/boot/vmlinuz.custom`，原内核仍保留在 `/boot/vmlinuz`，
`extlinux.conf` 同时提供 `custom` 和 `stock` 两个启动项。安装脚本在
`/etc/deviceinfo` 写入 `deviceinfo_generate_extlinux_config="false"`，防止
postmarketOS 的 `boot-deploy` 再次把默认内核改成 stock。若需要回退：

```sh
sudo rc-service mi5x-charge-control stop
sudo rc-update del mi5x-charge-control default
echo auto | sudo tee /sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

然后把 `/boot/extlinux/extlinux.conf` 中的 `default custom` 改为
`default stock` 并重启。若自定义内核无法启动，在启动菜单中直接选择 `stock`。
待机菜单保留 5 秒。

## 构建与测试

不涉及内核构建的静态检查和假 sysfs 测试：

```sh
make lint
make test
```

测试覆盖 ABI 检测、真实 sysfs 选中值格式、上下限转换、中间区间状态保持、
幂等写入、无效配置、服务收到 `SIGTERM` 后的干净退出，以及补丁内核启动项的
哈希校验、stock 回退项和重复安装。

从上游源码应用补丁并编译驱动对象需要 `git`、Clang/LLVM、Bison、Flex、bc、
OpenSSL 和 libelf 开发包：

```sh
./scripts/test-kernel-patch.sh v7.0.9-r0
./scripts/test-kernel-patch.sh v7.1.3-r0
```

脚本在临时目录克隆指定标签，先执行 `git apply --check`，再用 arm64
`defconfig` 打开驱动并编译 `qcom-smbchg.o`。它不会构建或安装完整内核。

## 真机验证状态

2026-10-26 已在 Mi 5X / Mi A1 (`tissot`) 上验证自定义内核启动、标准 ABI、
USB 供电保留、服务阈值转换、OpenRC 自动启动和服务重启/手机重启后的状态恢复。
完整充电周期、真实低于 60% 的恢复、拔插 USB 以及 WiFi 休眠/`s2idle` 尚未覆盖。
具体命令、哈希、观测值和限制见
[真机验证记录](docs/hardware-validation-2026-10-26.md)。

## 安全边界

- 不修改电池浮充电压，不直接写 PMIC 寄存器。
- 不通过 `input_current_limit` 或 `online=0` 模拟充电截止。
- 不承诺降温、修复老化电池或替代硬件保护电路。
- 长期接入电源仍应关注电池温度；软件阈值只减少高电量停留时间。

## License

GPL-2.0-only，见 [LICENSE](LICENSE)。
