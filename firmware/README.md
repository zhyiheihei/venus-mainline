# firmware/

固件来源与去向(M5 WiFi 里程碑落地):

| 目标 | 来源(LOS/小米 ROM) | 主线路径 |
| --- | --- | --- |
| WiFi WCN6855 板级校准 | `/vendor/firmware/wlan/`(boardfile) | `/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin` |
| WiFi amss/m3 固件 | `/vendor/firmware/` 或 ath11k-wcn6855 上游包 | `/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin`、`m3.bin` |
| BT | `/vendor/firmware/qca6390/`(amssbt、rampatch) | `/lib/firmware/qca/` |
| ADSP/CDSP/SLPI/Modem | LOS `firmware-update/dspso.bin` 或 vendor 分区 | `/lib/firmware/qcom/sm8350/venus/`(remoteproc 用) |

提取工具:dynamic partitions 用 payload-dumper-go 解 payload.bin;firmware-update/ 目录直接解 zip。

注意:固件文件来自厂商分发,只放本机 `/lib/firmware`,不入 git。
