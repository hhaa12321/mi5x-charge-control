# 2026-10-30 stock 内核回退导致充电失控

## 现象

2026-10-30 16:27，监控触发 `Mi5xBatteryChargingAboveCeiling` 警告。检查时电池
电量为 93%，`qcom-battery/status=Charging`，USB 输入在线。

`mi5x-charge-control` 已加入 OpenRC `default` 运行级，但服务停在 `stopped`。
手动执行检查得到：

```text
mi5x-charge-control: error: missing charge_behaviour ABI: /sys/class/power_supply/qcom-smbchg-usb/charge_behaviour
```

## 根因

10 月 29 日的服务日志仍有正常阈值转换：

```text
2026-10-29 06:16:04 battery 60%: charge behaviour inhibit-charge -> auto
2026-10-29 15:04:43 battery 75%: charge behaviour auto -> inhibit-charge
```

10 月 30 日 15:23，postmarketOS 包变更触发 `boot-deploy`，重新生成
`/boot/extlinux/extlinux.conf`。新配置的 `kernel` 指向 stock `/vmlinuz`，
而带 `charge_behaviour` 驱动补丁的已验证明仍完好保存在
`/boot/vmlinuz.custom`：

```text
stock vmlinuz        3998ceaae9b40b0c108d3b0ca83fc8ea937b676cd550453cdc6c07b14ee2822a
custom vmlinuz       16cf2edc0978bce8962a0cd2cc9d24391b740023512d282847a84e94d31c430e
```

custom 哈希与 2026-10-26 真机验证记录完全一致。因此控制器程序没有写错阈值，
失效点是包更新后启动项从补丁内核切回了 stock 内核。

## 修复

`scripts/install-kernel-boot-entry.sh` 做三件事：

- 校验用户提供的 custom 内核 SHA-256 和 gzip 镜像完整性。
- 生成带 `custom` 默认项和 `stock` 回退项的 `extlinux.conf`。
- 在 `/etc/deviceinfo` 设置 `deviceinfo_generate_extlinux_config="false"`，
  阻止后续 `boot-deploy` 覆盖固定启动项。

首次现场修复使用了错误的 `extlinux.conf`：缩进被写成字面量 `\t`，设备重启后
没有进入系统。通过 fastboot 临时启动已有的调试镜像，只读挂载 userdata 内的
root 分区、读写挂载 boot 分区，保存故障文件为
`extlinux.conf.broken-20261030`，再写入 2026-10-26 已验证配置。该配置为 609
字节，SHA-256 为：

```text
dfcdaa162ef524fced5f7654e2fddc60f551677da288f736ff679500a046d3c8
```

恢复前再次核对 stock、custom 和 initramfs 哈希，恢复后核对启动项哈希与
`root:root 0644` 权限，并确认缩进是实际制表符。安装脚本的测试现在逐字节比对
生成结果和该真机验证配置，避免再次生成不可启动的菜单。

固定启动项安装后必须重启验证。控制器仍只接受标准 `charge_behaviour` ABI；
如果补丁内核缺失或不兼容，服务会继续明确失败，不会改用输入限流、断开 USB
输入或直接写 PMIC 寄存器。

## 恢复结果

设备以 `7.0.9-msm8953` 补丁内核重新启动，USB 和局域网均恢复。服务在 default
运行级自动启动；2026-10-30 19:08:26 的日志记录：

```text
battery 98%: charge behaviour auto -> inhibit-charge
```

最终检查时电池为 97%、`status=Discharging`，charger `online=1`，
`charge_behaviour=auto [inhibit-charge]`。Prometheus 和 Alertmanager 中均不再
存在 `Mi5xBatteryChargingAboveCeiling`。恢复重启本身触发的
`HostUnexpectedReboot` 是预期告警，不属于充电控制故障。
