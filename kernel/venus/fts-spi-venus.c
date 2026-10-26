// SPDX-License-Identifier: GPL-2.0
// STMicroelectronics FTS Touchscreen device driver
//
// Copyright (c) 2017 Samsung Electronics Co., Ltd.
// Copyright (c) 2017 Andi Shyti <andi@etezian.org>

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/spi/spi.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>

/* I2C commands */
#define STMFTS_READ_INFO			0x80
#define STMFTS_READ_STATUS			0x84
#define STMFTS_READ_ONE_EVENT			0x85
#define STMFTS_READ_ALL_EVENT			0x86
#define STMFTS_LATEST_EVENT			0x87
#define STMFTS_SLEEP_IN				0x90
#define STMFTS_SLEEP_OUT			0x91
#define STMFTS_MS_MT_SENSE_OFF			0x92
#define STMFTS_MS_MT_SENSE_ON			0x93
#define STMFTS_SS_HOVER_SENSE_OFF		0x94
#define STMFTS_SS_HOVER_SENSE_ON		0x95
#define STMFTS_MS_KEY_SENSE_OFF			0x9a
#define STMFTS_MS_KEY_SENSE_ON			0x9b
#define STMFTS_SYSTEM_RESET			0xa0
#define STMFTS_CLEAR_EVENT_STACK		0xa1
#define STMFTS_FULL_FORCE_CALIBRATION		0xa2
#define STMFTS_MS_CX_TUNING			0xa3
#define STMFTS_SS_CX_TUNING			0xa4

/* events */
#define STMFTS_EV_NO_EVENT			0x00
#define STMFTS_EV_MULTI_TOUCH_DETECTED		0x02
#define STMFTS_EV_MULTI_TOUCH_ENTER		0x03
#define STMFTS_EV_MULTI_TOUCH_LEAVE		0x04
#define STMFTS_EV_MULTI_TOUCH_MOTION		0x05
#define STMFTS_EV_HOVER_ENTER			0x07
#define STMFTS_EV_HOVER_LEAVE			0x08
#define STMFTS_EV_HOVER_MOTION			0x09
#define STMFTS_EV_KEY_STATUS			0x0e
#define STMFTS_EV_ERROR				0x0f
#define STMFTS_EV_CONTROLLER_READY		0x10
#define STMFTS_EV_SLEEP_OUT_CONTROLLER_READY	0x11
#define STMFTS_EV_STATUS			0x16
#define STMFTS_EV_DEBUG				0xdb

/* multi touch related event masks */
#define STMFTS_MASK_EVENT_ID			0x0f
#define STMFTS_MASK_TOUCH_ID			0xf0
#define STMFTS_MASK_LEFT_EVENT			0x0f
#define STMFTS_MASK_X_MSB			0x0f
#define STMFTS_MASK_Y_LSB			0xf0

/* key related event masks */
#define STMFTS_MASK_KEY_NO_TOUCH		0x00
#define STMFTS_MASK_KEY_MENU			0x01
#define STMFTS_MASK_KEY_BACK			0x02

#define STMFTS_EVENT_SIZE	8
#define STMFTS_STACK_DEPTH	32
#define STMFTS_DATA_MAX_SIZE	(STMFTS_EVENT_SIZE * STMFTS_STACK_DEPTH)
#define STMFTS_MAX_FINGERS	10
#define STMFTS_DEV_NAME		"stmfts"

static const struct regulator_bulk_data stmfts_supplies[] = {
	{ .supply = "vdd" },
	{ .supply = "avdd" },
};

struct stmfts_data {
	struct spi_device *spi;
	struct device *dev;
	int irq;
	int num_supplies;
	struct input_dev *input;
	struct gpio_desc *reset_gpio;
	bool chip_ok;		/* 芯片 ID 探测是否通过 */
	struct led_classdev led_cdev;
	struct mutex mutex;

	struct touchscreen_properties prop;

	struct regulator_bulk_data *supplies;

	/*
	 * Presence of ledvdd will be used also to check
	 * whether the LED is supported.
	 */
	struct regulator *ledvdd;

	u16 chip_id;
	u8 chip_ver;
	u16 fw_ver;
	u8 config_id;
	u8 config_ver;

	u8 data[STMFTS_DATA_MAX_SIZE];

	struct completion cmd_done;

	bool use_key;
	bool led_status;
	bool hover_enabled;
	bool running;
};

static int stmfts_brightness_set(struct led_classdev *led_cdev,
				 enum led_brightness value)
{
	struct stmfts_data *sdata = container_of(led_cdev,
					struct stmfts_data, led_cdev);
	int err;

	if (value != sdata->led_status && sdata->ledvdd) {
		if (!value) {
			regulator_disable(sdata->ledvdd);
		} else {
			err = regulator_enable(sdata->ledvdd);
			if (err) {
				dev_warn(sdata->dev,
					 "failed to enable ledvdd regulator: %d\n",
					 err);
				return err;
			}
		}
		sdata->led_status = value;
	}

	return 0;
}

static enum led_brightness stmfts_brightness_get(struct led_classdev *led_cdev)
{
	struct stmfts_data *sdata = container_of(led_cdev,
						struct stmfts_data, led_cdev);

	return !!regulator_is_enabled(sdata->ledvdd);
}

/*
 * We can't simply use i2c_smbus_read_i2c_block_data because we
 * need to read 256 bytes, which exceeds the 255-byte SMBus block limit.
 */
/* ST FTS 在这台机器上是 3-wire SPI：先发命令字节，再在同一 CS 内读数据。 */
static int venus_fts_write(struct stmfts_data *sdata, u8 cmd)
{
	return spi_write(sdata->spi, &cmd, 1);
}

static int venus_fts_read_block(struct stmfts_data *sdata, u8 cmd, int len, u8 *buf)
{
	struct spi_transfer xfer[2] = { { 0 }, { 0 } };
	struct spi_message msg;
	u8 tmp[264];
	int ret;

	if (len + 1 > sizeof(tmp))
		return -EINVAL;

	/*
	 * 必须把「写命令」和「读数据」放进同一个 spi_message：
	 * FTS 在 SPI 上要求 CS 在整个 命令+数据 期间保持有效（等价于 I2C 的
	 * repeated start）。用 spi_write_then_read() 会在两者之间抬起 CS，
	 * 芯片于是放弃这次事务 → 读回全 0、INT 一直拉低造成 6500 万次中断。
	 */
	spi_message_init(&msg);

	xfer[0].tx_buf = &cmd;
	xfer[0].len = 1;
	spi_message_add_tail(&xfer[0], &msg);

	/*
	 * RX 侧会先收到我们刚发出去的命令字节（MISO 上看到 MOSI 的回显），
	 * 所以多读 1 字节再丢掉它，剩下的才是芯片数据。
	 */
	xfer[1].rx_buf = tmp;
	xfer[1].len = len + 1;
	spi_message_add_tail(&xfer[1], &msg);

	ret = spi_sync(sdata->spi, &msg);
	if (ret < 0)
		return ret;

	if (len <= 16)
		dev_info(sdata->dev, "venus-fts: 原始读 cmd=0x%02x -> [%*ph]\n",
			 cmd, len + 1, tmp);

	if (tmp[0] == cmd)
		memcpy(buf, tmp + 1, len);
	else
		memcpy(buf, tmp, len);

	return len;
}

static int stmfts_read_events(struct stmfts_data *sdata)
{
	u8 cmd = STMFTS_READ_ALL_EVENT;

	return venus_fts_read_block(sdata, cmd, STMFTS_DATA_MAX_SIZE, sdata->data) < 0 ? -EIO : 0;
}

static void stmfts_report_contact_event(struct stmfts_data *sdata,
					const u8 event[])
{
	u8 slot_id = (event[0] & STMFTS_MASK_TOUCH_ID) >> 4;
	u16 x = event[1] | ((event[2] & STMFTS_MASK_X_MSB) << 8);
	u16 y = (event[2] >> 4) | (event[3] << 4);
	u8 maj = event[4];
	u8 min = event[5];
	u8 orientation = event[6];
	u8 area = event[7];

	input_mt_slot(sdata->input, slot_id);

	input_mt_report_slot_state(sdata->input, MT_TOOL_FINGER, true);
	input_report_abs(sdata->input, ABS_MT_POSITION_X, x);
	input_report_abs(sdata->input, ABS_MT_POSITION_Y, y);
	input_report_abs(sdata->input, ABS_MT_TOUCH_MAJOR, maj);
	input_report_abs(sdata->input, ABS_MT_TOUCH_MINOR, min);
	input_report_abs(sdata->input, ABS_MT_PRESSURE, area);
	input_report_abs(sdata->input, ABS_MT_ORIENTATION, orientation);

	input_sync(sdata->input);
}

static void stmfts_report_contact_release(struct stmfts_data *sdata,
					  const u8 event[])
{
	u8 slot_id = (event[0] & STMFTS_MASK_TOUCH_ID) >> 4;

	input_mt_slot(sdata->input, slot_id);
	input_mt_report_slot_inactive(sdata->input);

	input_sync(sdata->input);
}

static void stmfts_report_hover_event(struct stmfts_data *sdata,
				      const u8 event[])
{
	u16 x = (event[2] << 4) | (event[4] >> 4);
	u16 y = (event[3] << 4) | (event[4] & STMFTS_MASK_Y_LSB);
	u8 z = event[5];

	input_report_abs(sdata->input, ABS_X, x);
	input_report_abs(sdata->input, ABS_Y, y);
	input_report_abs(sdata->input, ABS_DISTANCE, z);

	input_sync(sdata->input);
}

static void stmfts_report_key_event(struct stmfts_data *sdata, const u8 event[])
{
	switch (event[2]) {
	case 0:
		input_report_key(sdata->input, KEY_BACK, 0);
		input_report_key(sdata->input, KEY_MENU, 0);
		break;

	case STMFTS_MASK_KEY_BACK:
		input_report_key(sdata->input, KEY_BACK, 1);
		break;

	case STMFTS_MASK_KEY_MENU:
		input_report_key(sdata->input, KEY_MENU, 1);
		break;

	default:
		dev_warn(sdata->dev,
			 "unknown key event: %#02x\n", event[2]);
		break;
	}

	input_sync(sdata->input);
}

static void stmfts_parse_events(struct stmfts_data *sdata)
{
	int i;

	for (i = 0; i < STMFTS_STACK_DEPTH; i++) {
		u8 *event = &sdata->data[i * STMFTS_EVENT_SIZE];

		switch (event[0]) {
		case STMFTS_EV_CONTROLLER_READY:
		case STMFTS_EV_SLEEP_OUT_CONTROLLER_READY:
		case STMFTS_EV_STATUS:
			complete(&sdata->cmd_done);
			fallthrough;

		case STMFTS_EV_NO_EVENT:
		case STMFTS_EV_DEBUG:
			return;
		}

		switch (event[0] & STMFTS_MASK_EVENT_ID) {
		case STMFTS_EV_MULTI_TOUCH_ENTER:
		case STMFTS_EV_MULTI_TOUCH_MOTION:
			stmfts_report_contact_event(sdata, event);
			break;

		case STMFTS_EV_MULTI_TOUCH_LEAVE:
			stmfts_report_contact_release(sdata, event);
			break;

		case STMFTS_EV_HOVER_ENTER:
		case STMFTS_EV_HOVER_LEAVE:
		case STMFTS_EV_HOVER_MOTION:
			stmfts_report_hover_event(sdata, event);
			break;

		case STMFTS_EV_KEY_STATUS:
			stmfts_report_key_event(sdata, event);
			break;

		case STMFTS_EV_ERROR:
			dev_warn(sdata->dev,
				 "error code: 0x%x%x%x%x%x%x",
				 event[6], event[5], event[4],
				 event[3], event[2], event[1]);
			break;

		default:
			dev_err(sdata->dev,
				"unknown event %#02x\n", event[0]);
		}
	}
}

static irqreturn_t stmfts_irq_handler(int irq, void *dev)
{
	struct stmfts_data *sdata = dev;
	int err;

	guard(mutex)(&sdata->mutex);

	err = stmfts_read_events(sdata);
	if (unlikely(err))
		dev_err(sdata->dev,
			"failed to read events: %d\n", err);
	else
		stmfts_parse_events(sdata);

	return IRQ_HANDLED;
}

static int stmfts_command(struct stmfts_data *sdata, const u8 cmd)
{
	int err;

	reinit_completion(&sdata->cmd_done);

	err = venus_fts_write(sdata, cmd);
	if (err)
		return err;

	if (!wait_for_completion_timeout(&sdata->cmd_done,
					 msecs_to_jiffies(1000)))
		return -ETIMEDOUT;

	return 0;
}

static int stmfts_input_open(struct input_dev *dev)
{
	struct stmfts_data *sdata = input_get_drvdata(dev);
	int err;

	err = pm_runtime_resume_and_get(sdata->dev);
	if (err)
		return err;

	err = venus_fts_write(sdata, STMFTS_MS_MT_SENSE_ON);
	if (err) {
		pm_runtime_put_sync(sdata->dev);
		return err;
	}

	scoped_guard(mutex, &sdata->mutex) {
		sdata->running = true;

		if (sdata->hover_enabled) {
			err = venus_fts_write(sdata, STMFTS_SS_HOVER_SENSE_ON);
			if (err)
				dev_warn(sdata->dev,
					 "failed to enable hover\n");
		}
	}

	if (sdata->use_key) {
		err = venus_fts_write(sdata, STMFTS_MS_KEY_SENSE_ON);
		if (err)
			/* I can still use only the touch screen */
			dev_warn(sdata->dev,
				 "failed to enable touchkey\n");
	}

	return 0;
}

static void stmfts_input_close(struct input_dev *dev)
{
	struct stmfts_data *sdata = input_get_drvdata(dev);
	int err;

	err = venus_fts_write(sdata, STMFTS_MS_MT_SENSE_OFF);
	if (err)
		dev_warn(sdata->dev,
			 "failed to disable touchscreen: %d\n", err);

	scoped_guard(mutex, &sdata->mutex) {
		sdata->running = false;

		if (sdata->hover_enabled) {
			err = venus_fts_write(sdata, STMFTS_SS_HOVER_SENSE_OFF);
			if (err)
				dev_warn(sdata->dev,
					 "failed to disable hover: %d\n", err);
		}
	}

	if (sdata->use_key) {
		err = venus_fts_write(sdata, STMFTS_MS_KEY_SENSE_OFF);
		if (err)
			dev_warn(sdata->dev,
				 "failed to disable touchkey: %d\n", err);
	}

	pm_runtime_put_sync(sdata->dev);
}

static ssize_t stmfts_sysfs_chip_id(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%#x\n", sdata->chip_id);
}

static ssize_t stmfts_sysfs_chip_version(struct device *dev,
					 struct device_attribute *attr,
					 char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", sdata->chip_ver);
}

static ssize_t stmfts_sysfs_fw_ver(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", sdata->fw_ver);
}

static ssize_t stmfts_sysfs_config_id(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%#x\n", sdata->config_id);
}

static ssize_t stmfts_sysfs_config_version(struct device *dev,
					   struct device_attribute *attr,
					   char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", sdata->config_ver);
}

static ssize_t stmfts_sysfs_read_status(struct device *dev,
					struct device_attribute *attr,
					char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);
	u8 status[4];
	int err;

	err = venus_fts_read_block(sdata, STMFTS_READ_STATUS,
					    sizeof(status), status);
	if (err)
		return err;

	return sysfs_emit(buf, "%#02x\n", status[0]);
}

static ssize_t stmfts_sysfs_hover_enable_read(struct device *dev,
					      struct device_attribute *attr,
					      char *buf)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", sdata->hover_enabled);
}

static ssize_t stmfts_sysfs_hover_enable_write(struct device *dev,
					       struct device_attribute *attr,
					       const char *buf, size_t len)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);
	unsigned long value;
	bool hover;
	int err;

	if (kstrtoul(buf, 0, &value))
		return -EINVAL;

	hover = !!value;

	guard(mutex)(&sdata->mutex);

	if (hover != sdata->hover_enabled) {
		if (sdata->running) {
			err = venus_fts_write(sdata, value ? STMFTS_SS_HOVER_SENSE_ON :
							   STMFTS_SS_HOVER_SENSE_OFF);
			if (err)
				return err;
		}

		sdata->hover_enabled = hover;
	}

	return len;
}

static DEVICE_ATTR(chip_id, 0444, stmfts_sysfs_chip_id, NULL);
static DEVICE_ATTR(chip_version, 0444, stmfts_sysfs_chip_version, NULL);
static DEVICE_ATTR(fw_ver, 0444, stmfts_sysfs_fw_ver, NULL);
static DEVICE_ATTR(config_id, 0444, stmfts_sysfs_config_id, NULL);
static DEVICE_ATTR(config_version, 0444, stmfts_sysfs_config_version, NULL);
static DEVICE_ATTR(status, 0444, stmfts_sysfs_read_status, NULL);
static DEVICE_ATTR(hover_enable, 0644, stmfts_sysfs_hover_enable_read,
					stmfts_sysfs_hover_enable_write);

static struct attribute *stmfts_sysfs_attrs[] = {
	&dev_attr_chip_id.attr,
	&dev_attr_chip_version.attr,
	&dev_attr_fw_ver.attr,
	&dev_attr_config_id.attr,
	&dev_attr_config_version.attr,
	&dev_attr_status.attr,
	&dev_attr_hover_enable.attr,
	NULL
};
ATTRIBUTE_GROUPS(stmfts_sysfs);

static int stmfts_read_system_info(struct stmfts_data *sdata)
{
	int err;
	u8 reg[8];

	err = venus_fts_read_block(sdata, STMFTS_READ_INFO,
					    sizeof(reg), reg);
	if (err < 0)
		return err;
	if (err != sizeof(reg))
		return -EIO;

	sdata->chip_id = be16_to_cpup((__be16 *)&reg[6]);
	sdata->chip_ver = reg[0];
	sdata->fw_ver = be16_to_cpup((__be16 *)&reg[2]);
	sdata->config_id = reg[4];
	sdata->config_ver = reg[5];

	return 0;
}


/*
 * ST FTS 的 SPI 命令是「命令字节 + 大端地址」的帧，不是单字节。
 * 依据厂商 fts_lib（Evolution-X kernel_xiaomi_venus, fts_spi/fts_lib）：
 *   fts_writeReadU8UX(cmd, addrSize, address, out, len, hasDummyByte)
 *     finalCmd[0] = cmd; finalCmd[i+1] = address >> ((addrSize-1-i)*8) & 0xFF
 *     SPI: DUMMY_HW_REG/DUMMY_FIFO = 1 → 读 len+1 字节，丢掉第 0 字节
 *   芯片 ID: fts_writeReadU8UX(0xFA, ADDR_SIZE_HW_REG, 0x20000000, buf, 2, 1)
 *   期望值: DCHIP_ID_0 = 0x36, DCHIP_ID_1 ∈ {0x48, 0x50, 0x40, 0x39}
 */
/*
 * 按厂商 fts_lib（Evolution-X kernel_xiaomi_venus, fts_spi/fts_lib）复刻的最小存活检测：
 *
 *   1) 上电时序（fts_chip_powercycle）：复位保持有效（物理低）→ 开 vdd → 1ms → 开 avdd
 *      → 5ms → 10ms → 释放复位（物理高）
 *   2) 复位脉冲（fts_system_reset 走 GPIO 分支）：拉低 10ms，拉高
 *   3) 读 FIFO 事件（pollForEvent）：命令 0x87 + 读 8 字节，SPI 下第一个字节是 dummy，
 *      事件首字节 0x03 = EVT_ID_CONTROLLER_READY
 *
 * 我们的 reset-gpios 是 GPIO_ACTIVE_LOW，所以 gpiod_set_value(1) = 物理低 = 复位有效。
 */
#define FTS_EVT_CONTROLLER_READY	0x03
#define FTS_FIFO_CMD_READONE		0x87
#define FTS_FIFO_EVENT_SIZE		8

static int venus_fts_read_event(struct stmfts_data *sdata, u8 *ev)
{
	struct spi_transfer xfer[2] = { { 0 }, { 0 } };
	struct spi_message msg;
	u8 cmd = FTS_FIFO_CMD_READONE;
	u8 rx[FTS_FIFO_EVENT_SIZE + 1] = { 0 };
	int ret;

	spi_message_init(&msg);
	xfer[0].tx_buf = &cmd;
	xfer[0].len = 1;
	spi_message_add_tail(&xfer[0], &msg);
	xfer[1].rx_buf = rx;
	xfer[1].len = sizeof(rx);
	xfer[1].delay.value = 10;
	xfer[1].delay.unit = SPI_DELAY_UNIT_USECS;
	spi_message_add_tail(&xfer[1], &msg);

	ret = spi_sync(sdata->spi, &msg);
	if (ret < 0)
		return ret;

	memcpy(ev, rx + 1, FTS_FIFO_EVENT_SIZE);	/* SPI 下第 0 字节是 dummy */
	return 0;
}

static void venus_fts_read_hw_chipid(struct stmfts_data *sdata)
{
	struct spi_transfer xfer[2] = { { 0 }, { 0 } };
	struct spi_message msg;
	u64 addr = 0x20000000ULL;	/* ADDR_DCHIP_ID */
	u8 cmd[5];
	u8 rx[3] = { 0 };
	int i;

	cmd[0] = 0xfa;			/* FTS_CMD_HW_REG_R */
	for (i = 0; i < 4; i++)
		cmd[i + 1] = (u8)((addr >> ((3 - i) * 8)) & 0xff);

	spi_message_init(&msg);
	xfer[0].tx_buf = cmd;
	xfer[0].len = 5;
	spi_message_add_tail(&xfer[0], &msg);
	xfer[1].rx_buf = rx;
	xfer[1].len = 3;		/* 2 字节 + dummy */
	spi_message_add_tail(&xfer[1], &msg);

	if (spi_sync(sdata->spi, &msg) == 0)
		dev_info(sdata->dev,
			 "venus-fts: 硬件 chip id 原始 [%*ph] → 0x%02x 0x%02x\n",
			 3, rx, rx[1], rx[2]);
}

static bool venus_fts_probe_chipid(struct stmfts_data *sdata)
{
	u8 ev[FTS_FIFO_EVENT_SIZE];
	int i;

	/* 1) 上电时序 */
	gpiod_set_value_cansleep(sdata->reset_gpio, 1);	/* 复位有效（物理低） */
	regulator_disable(sdata->supplies[0].consumer);
	regulator_disable(sdata->supplies[1].consumer);
	msleep(20);
	regulator_enable(sdata->supplies[0].consumer);	/* vdd */
	msleep(2);
	regulator_enable(sdata->supplies[1].consumer);	/* avdd */
	msleep(6);
	msleep(10);
	gpiod_set_value_cansleep(sdata->reset_gpio, 0);	/* 释放复位（物理高） */
	msleep(10);

	/* 2) 复位脉冲 */
	gpiod_set_value_cansleep(sdata->reset_gpio, 1);
	msleep(12);
	gpiod_set_value_cansleep(sdata->reset_gpio, 0);
	msleep(5);

	/* 3) 轮询 controller-ready 事件 */
	for (i = 0; i < 200; i++) {
		if (venus_fts_read_event(sdata, ev) < 0)
			break;
		if (ev[0] && ev[0] != 0xff) {
			dev_info(sdata->dev,
				 "venus-fts: 第 %d 次读到事件 [%*ph]%s\n", i,
				 FTS_FIFO_EVENT_SIZE, ev,
				 ev[0] == FTS_EVT_CONTROLLER_READY ? "  <<< 芯片就绪" : "");
		}
		if (ev[0] == FTS_EVT_CONTROLLER_READY) {
			venus_fts_read_hw_chipid(sdata);
			return true;
		}
		msleep(10);
	}

	dev_info(sdata->dev, "venus-fts: 200 次轮询没有 controller-ready\n");
	return false;
}

static void stmfts_reset(struct stmfts_data *sdata)
{
	gpiod_set_value_cansleep(sdata->reset_gpio, 1);
	msleep(20);

	gpiod_set_value_cansleep(sdata->reset_gpio, 0);
	msleep(50);
}

static int stmfts_configure(struct stmfts_data *sdata)
{
	int err;

	err = stmfts_command(sdata, STMFTS_SYSTEM_RESET);
	if (err)
		return err;

	err = stmfts_command(sdata, STMFTS_SLEEP_OUT);
	if (err)
		return err;

	/* optional tuning */
	err = stmfts_command(sdata, STMFTS_MS_CX_TUNING);
	if (err)
		dev_warn(sdata->dev,
			 "failed to perform mutual auto tune: %d\n", err);

	/* optional tuning */
	err = stmfts_command(sdata, STMFTS_SS_CX_TUNING);
	if (err)
		dev_warn(sdata->dev,
			 "failed to perform self auto tune: %d\n", err);

	err = stmfts_command(sdata, STMFTS_FULL_FORCE_CALIBRATION);
	if (err)
		return err;

	return 0;
}

static int stmfts_power_on(struct stmfts_data *sdata)
{
	int err, i;
	u8 info[8] = { 0 };

	/* 按厂商 fts_power_cycle 的顺序：先按住复位再上电，最后释放复位 */
	if (sdata->reset_gpio)
		gpiod_set_value_cansleep(sdata->reset_gpio, 1);

	err = regulator_enable(sdata->supplies[0].consumer);	/* vdd */
	dev_info(sdata->dev, "venus-fts: vdd enable rc=%d\n", err);
	msleep(2);

	err = regulator_enable(sdata->supplies[1].consumer);	/* avdd */
	dev_info(sdata->dev, "venus-fts: avdd enable rc=%d\n", err);
	msleep(6);

	for (i = 0; i < sdata->num_supplies; i++)
		dev_info(sdata->dev, "venus-fts: supply[%d] %s enabled=%d\n", i,
			 sdata->supplies[i].supply,
			 regulator_is_enabled(sdata->supplies[i].consumer));

	msleep(10);
	if (sdata->reset_gpio)
		gpiod_set_value_cansleep(sdata->reset_gpio, 0);	/* 释放复位 */
	msleep(100);
	dev_info(sdata->dev, "venus-fts: 复位已释放，按厂商帧格式探测芯片 ID\n");
	sdata->chip_ok = venus_fts_probe_chipid(sdata);

	/* 全双工读：边发 0xFF 边收，若 MISO 与 MOSI 共线则能看出芯片是否在驱动 */
	{
		u8 t[17], r[17];
		int k;

		memset(t, 0xff, sizeof(t));
		t[0] = STMFTS_READ_INFO;
		memset(r, 0, sizeof(r));
		spi_write_then_read(sdata->spi, NULL, 0, NULL, 0);	/* no-op */
		{
			struct spi_transfer x = { .tx_buf = t, .rx_buf = r, .len = 9 };
			struct spi_message m;

			spi_message_init(&m);
			spi_message_add_tail(&x, &m);
			spi_sync(sdata->spi, &m);
		}
		dev_info(sdata->dev, "venus-fts: 全双工读 0x80 -> [%*ph]\n", 9, r);
		for (k = 0; k < 9; k++)
			t[k] = 0xff;
	}

	/* 总线自检：换几个命令码看首字节是否跟着变，判断是回显还是芯片应答 */
	{
		static const u8 probe_cmds[] = { 0x84, 0xa8, 0x55, 0xaa };
		int k;

		for (k = 0; k < ARRAY_SIZE(probe_cmds); k++) {
			u8 raw[9] = { 0 };

			venus_fts_read_block(sdata, probe_cmds[k], 8, raw);
			dev_info(sdata->dev, "venus-fts: 总线自检 cmd=0x%02x 首字节=0x%02x\n",
				 probe_cmds[k], raw[0]);
		}
	}

	err = venus_fts_read_block(sdata, STMFTS_READ_INFO, 8, info);
	dev_info(sdata->dev, "venus-fts: info rc=%d [%02x %02x %02x %02x %02x %02x %02x %02x]\n",
		 err, info[0], info[1], info[2], info[3], info[4], info[5], info[6], info[7]);
	if (err < 0)
		return err;

	sdata->chip_id = be16_to_cpup((__be16 *)&info[6]);
	sdata->chip_ver = info[0];
	sdata->fw_ver = be16_to_cpup((__be16 *)&info[2]);
	sdata->config_id = info[4];
	sdata->config_ver = info[5];
	dev_info(sdata->dev, "venus-fts: chip_id=0x%04x ver=0x%02x fw=0x%04x cfg=0x%02x/%02x\n",
		 sdata->chip_id, sdata->chip_ver, sdata->fw_ver,
		 sdata->config_id, sdata->config_ver);

	enable_irq(sdata->irq);
	msleep(50);

	return 0;
}

static void stmfts_power_off(void *data)
{
	struct stmfts_data *sdata = data;

	disable_irq(sdata->irq);

	if (sdata->reset_gpio)
		gpiod_set_value_cansleep(sdata->reset_gpio, 1);

	regulator_bulk_disable(ARRAY_SIZE(stmfts_supplies), sdata->supplies);
}

static int stmfts_enable_led(struct stmfts_data *sdata)
{
	int err;

	/* get the regulator for powering the leds on */
	sdata->ledvdd = devm_regulator_get(sdata->dev, "ledvdd");
	if (IS_ERR(sdata->ledvdd))
		return PTR_ERR(sdata->ledvdd);

	sdata->led_cdev.name = STMFTS_DEV_NAME;
	sdata->led_cdev.max_brightness = LED_ON;
	sdata->led_cdev.brightness = LED_OFF;
	sdata->led_cdev.brightness_set_blocking = stmfts_brightness_set;
	sdata->led_cdev.brightness_get = stmfts_brightness_get;

	err = devm_led_classdev_register(sdata->dev, &sdata->led_cdev);
	if (err) {
		devm_regulator_put(sdata->ledvdd);
		return err;
	}

	return 0;
}

static int venus_fts_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	int err;
	struct stmfts_data *sdata;


	sdata = devm_kzalloc(dev, sizeof(*sdata), GFP_KERNEL);
	if (!sdata)
		return -ENOMEM;

	spi_set_drvdata(spi, sdata);

	sdata->spi = spi;
	sdata->dev = dev;
	sdata->irq = spi->irq;
	mutex_init(&sdata->mutex);
	init_completion(&sdata->cmd_done);

	sdata->num_supplies = ARRAY_SIZE(stmfts_supplies);
	err = devm_regulator_bulk_get_const(dev, sdata->num_supplies,
					    stmfts_supplies,
					    &sdata->supplies);
	if (err)
		return err;

	sdata->reset_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(sdata->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(sdata->reset_gpio),
				     "Failed to get GPIO 'reset'\n");

	sdata->input = devm_input_allocate_device(dev);
	if (!sdata->input)
		return -ENOMEM;

	sdata->input->name = STMFTS_DEV_NAME;
	sdata->input->id.bustype = BUS_I2C;
	sdata->input->open = stmfts_input_open;
	sdata->input->close = stmfts_input_close;

	input_set_capability(sdata->input, EV_ABS, ABS_MT_POSITION_X);
	input_set_capability(sdata->input, EV_ABS, ABS_MT_POSITION_Y);
	touchscreen_parse_properties(sdata->input, true, &sdata->prop);

	input_set_abs_params(sdata->input, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	input_set_abs_params(sdata->input, ABS_MT_TOUCH_MINOR, 0, 255, 0, 0);
	input_set_abs_params(sdata->input, ABS_MT_ORIENTATION, 0, 255, 0, 0);
	input_set_abs_params(sdata->input, ABS_MT_PRESSURE, 0, 255, 0, 0);
	input_set_abs_params(sdata->input, ABS_DISTANCE, 0, 255, 0, 0);

	sdata->use_key = device_property_read_bool(dev, "touch-key-connected");
	if (sdata->use_key) {
		input_set_capability(sdata->input, EV_KEY, KEY_MENU);
		input_set_capability(sdata->input, EV_KEY, KEY_BACK);
	}

	err = input_mt_init_slots(sdata->input,
				  STMFTS_MAX_FINGERS, INPUT_MT_DIRECT);
	if (err)
		return err;

	input_set_drvdata(sdata->input, sdata);

	/*
	 * stmfts_power_on expects interrupt to be disabled, but
	 * at this point the device is still off and I do not trust
	 * the status of the irq line that can generate some spurious
	 * interrupts. To be on the safe side it's better to not enable
	 * the interrupts during their request.
	 */
	dev_dbg(dev, "initializing ST-Microelectronics FTS...\n");

	err = stmfts_power_on(sdata);
	if (err)
		return err;

	if (!sdata->chip_ok) {
		/*
		 * 芯片 ID 都对不上就注册中断，会因 INT 引脚常低造成中断风暴
		 * （之前把整机拖死过）。这里直接放弃注册中断。
		 */
		dev_err(dev, "venus-fts: 芯片 ID 不匹配，跳过中断与事件注册\n");
		return -ENODEV;
	}

	err = devm_request_threaded_irq(dev, spi->irq,
					NULL, stmfts_irq_handler,
					IRQF_ONESHOT | IRQF_NO_AUTOEN,
					"stmfts_irq", sdata);
	if (err)
		return err;

	err = devm_add_action_or_reset(dev, stmfts_power_off, sdata);
	if (err)
		return err;

	err = input_register_device(sdata->input);
	if (err)
		return err;

	if (sdata->use_key) {
		err = stmfts_enable_led(sdata);
		if (err) {
			/*
			 * Even if the LEDs have failed to be initialized and
			 * used in the driver, I can still use the device even
			 * without LEDs. The ledvdd regulator pointer will be
			 * used as a flag.
			 */
			dev_warn(dev, "unable to use touchkey leds\n");
			sdata->ledvdd = NULL;
		}
	}

	pm_runtime_enable(dev);
	device_enable_async_suspend(dev);

	return 0;
}

static void venus_fts_remove(struct spi_device *spi)
{
	pm_runtime_disable(&spi->dev);
}

static int stmfts_runtime_suspend(struct device *dev)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);
	int ret;

	ret = venus_fts_write(sdata, STMFTS_SLEEP_IN);
	if (ret)
		dev_warn(dev, "failed to suspend device: %d\n", ret);

	return ret;
}

static int stmfts_runtime_resume(struct device *dev)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	int ret;

	ret = venus_fts_write(sdata, STMFTS_SLEEP_OUT);
	if (ret)
		dev_err(dev, "failed to resume device: %d\n", ret);

	return ret;
}

static int stmfts_suspend(struct device *dev)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	stmfts_power_off(sdata);

	return 0;
}

static int stmfts_resume(struct device *dev)
{
	struct stmfts_data *sdata = dev_get_drvdata(dev);

	return stmfts_power_on(sdata);
}

static const struct dev_pm_ops stmfts_pm_ops = {
	SYSTEM_SLEEP_PM_OPS(stmfts_suspend, stmfts_resume)
	RUNTIME_PM_OPS(stmfts_runtime_suspend, stmfts_runtime_resume, NULL)
};

static const struct of_device_id venus_fts_of_match[] = {
	{ .compatible = "st,venus-fts" },
	{ }
};
MODULE_DEVICE_TABLE(of, venus_fts_of_match);

static struct spi_driver venus_fts_driver = {
	.probe = venus_fts_probe,
	.remove = venus_fts_remove,
	.driver = {
		.name = "venus-fts-ts",
		.of_match_table = venus_fts_of_match,
		.pm = pm_ptr(&stmfts_pm_ops),
	},
};
module_spi_driver(venus_fts_driver);

MODULE_AUTHOR("Andi Shyti <andi.shyti@samsung.com>");
MODULE_DESCRIPTION("STMicroelectronics FTS Touch Screen");
MODULE_LICENSE("GPL");
