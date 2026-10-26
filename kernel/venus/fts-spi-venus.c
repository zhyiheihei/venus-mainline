// SPDX-License-Identifier: GPL-2.0
/*
 * STMicroelectronics FTS 触摸屏驱动（小米 11 / venus，3-wire SPI）
 *
 * 协议与时序全部照抄厂商实现
 * （Evolution-X-Devices/kernel_xiaomi_venus, drivers/input/touchscreen/fts_spi）：
 *
 *  - 上电（fts_chip_powercycle）：复位保持有效 → vdd → 1ms → avdd → 5ms → 10ms → 释放复位
 *  - 复位脉冲（fts_system_reset 的 GPIO 分支）：拉低 10ms → 拉高
 *  - 读 FIFO 事件（pollForEvent）：命令 0x87 + 读 8 字节，SPI 下第 0 字节是 dummy
 *  - 事件首字节 0x03 = EVT_ID_CONTROLLER_READY
 *  - 读系统信息：writeSysCmd(0xA4,0x06,{0x01}) 后读 framebuffer 208 字节（命令 0xA7）
 *  - 开扫描：{0xA0, mode, settings}
 *  - 触点事件：0x13 enter / 0x23 motion / 0x33 leave
 *      id  = (e[1] & 0xF0) >> 4, 类型 = e[1] & 0x0F
 *      x   = ((e[3] & 0x0F) << 8) | e[2]
 *      y   = (e[4] << 4) | ((e[3] & 0xF0) >> 4)
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/interrupt.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/regulator/consumer.h>
#include <linux/spi/spi.h>

/* 厂商协议常量 */
#define FTS_CMD_FIFO_READONE	0x87
#define FTS_CMD_FRAMEBUFFER_R	0xA7
#define FTS_CMD_SYSTEM		0xA4
#define FTS_CMD_SCAN_MODE	0xA0

#define FTS_SYS_CMD_LOAD_DATA	0x06
#define FTS_LOAD_SYS_INFO	0x01
#define FTS_SCAN_MODE_ACTIVE	0x00

#define FTS_EVENT_SIZE		8
#define FTS_MAX_EVENTS		32
#define FTS_FIFO_READALL	0x87	/* SPI 下 READALL/READONE 同码：一次取回 FIFO 里所有事件 */
#define FTS_EVT_NOEVENT		0x00
#define FTS_EVT_CONTROLLER_READY	0x03
#define FTS_EVT_ENTER_POINT	0x13
#define FTS_EVT_MOTION_POINT	0x23
#define FTS_EVT_LEAVE_POINT	0x33
#define FTS_EVT_STATUS_UPDATE	0x43
#define FTS_EVT_USER_REPORT	0x53
#define FTS_EVT_DEBUG		0xE3
#define FTS_EVT_ERROR		0xF3

#define FTS_TOUCH_TYPE_FINGER	0x01
#define FTS_TOUCH_TYPE_GLOVE	0x02
#define FTS_TOUCH_TYPE_HOVER	0x03

#define FTS_SYSINFO_SIZE	208
#define FTS_MAX_FINGERS		10
#define FTS_CS_DELAY_US		10

struct venus_fts {
	struct spi_device *spi;
	struct device *dev;
	struct input_dev *input;
	struct gpio_desc *reset_gpio;
	struct regulator_bulk_data *supplies;
	int num_supplies;
	int irq;
	struct mutex lock;	/* 保护 SPI 事务与事件读取 */
	u16 x_max;
	u16 y_max;
	bool ready;
	struct delayed_work poll_work;	/* 调试用轮询：绕开中断直接读事件 */
	unsigned int poll_ms;
	int log_budget;
};

/* ---------- 底层 SPI 事务 ---------- */

/*
 * 厂商 fts_write_read：命令与数据必须在同一个 CS 内（同一个 spi_message 的两段 transfer），
 * 中间抬起 CS 芯片会丢弃整次事务。读到的第 0 字节是 dummy，需要丢掉。
 */
static int venus_fts_xfer(struct venus_fts *ts, const u8 *tx, int tx_len,
			  u8 *rx, int rx_len)
{
	struct spi_transfer xfer[2] = { { 0 }, { 0 } };
	struct spi_message msg;
	int ret;

	spi_message_init(&msg);

	xfer[0].tx_buf = tx;
	xfer[0].len = tx_len;
	xfer[0].delay.value = FTS_CS_DELAY_US;
	xfer[0].delay.unit = SPI_DELAY_UNIT_USECS;
	spi_message_add_tail(&xfer[0], &msg);

	if (rx && rx_len) {
		xfer[1].rx_buf = rx;
		xfer[1].len = rx_len + 1;	/* dummy + 数据 */
		xfer[1].delay.value = FTS_CS_DELAY_US;
		xfer[1].delay.unit = SPI_DELAY_UNIT_USECS;
		spi_message_add_tail(&xfer[1], &msg);
	}

	ret = spi_sync(ts->spi, &msg);
	if (ret)
		return ret;

	if (rx && rx_len)
		memmove(rx, rx + 1, rx_len);

	return 0;
}

static int venus_fts_write(struct venus_fts *ts, const u8 *tx, int len)
{
	return venus_fts_xfer(ts, tx, len, NULL, 0);
}

static int venus_fts_read_event(struct venus_fts *ts, u8 *ev)
{
	u8 cmd = FTS_CMD_FIFO_READONE;

	return venus_fts_xfer(ts, &cmd, 1, ev, FTS_EVENT_SIZE);
}

/* 一次 SPI 事务把 FIFO 里的事件全部取回，减少往返（响应速度的关键） */
static int venus_fts_read_all(struct venus_fts *ts, u8 *events, int *count)
{
	u8 cmd = FTS_FIFO_READALL;
	int ret, i;

	ret = venus_fts_xfer(ts, &cmd, 1, events, FTS_EVENT_SIZE * FTS_MAX_EVENTS);
	if (ret)
		return ret;

	for (i = 0; i < FTS_MAX_EVENTS; i++) {
		if (events[i * FTS_EVENT_SIZE] == FTS_EVT_NOEVENT)
			break;
	}
	*count = i;

	return 0;
}

/* ---------- 上电 / 复位 ---------- */

static void venus_fts_power_cycle(struct venus_fts *ts)
{
	/* 复位保持有效（reset-gpios 是 ACTIVE_LOW，set(1) = 物理低） */
	gpiod_set_value_cansleep(ts->reset_gpio, 1);

	regulator_disable(ts->supplies[0].consumer);
	regulator_disable(ts->supplies[1].consumer);
	msleep(20);

	regulator_enable(ts->supplies[0].consumer);	/* vdd 1.8V */
	msleep(2);
	regulator_enable(ts->supplies[1].consumer);	/* avdd 3.3V */
	msleep(6);
	msleep(10);

	/* 释放复位 */
	gpiod_set_value_cansleep(ts->reset_gpio, 0);
	msleep(10);

	/* 复位脉冲 */
	gpiod_set_value_cansleep(ts->reset_gpio, 1);
	msleep(12);
	gpiod_set_value_cansleep(ts->reset_gpio, 0);
	msleep(5);
}

/* ---------- 协议步骤 ---------- */

static int venus_fts_wait_ready(struct venus_fts *ts)
{
	u8 ev[FTS_EVENT_SIZE];
	int i, ret;

	for (i = 0; i < 200; i++) {
		ret = venus_fts_read_event(ts, ev);
		if (ret)
			return ret;
		if (ev[0] == FTS_EVT_CONTROLLER_READY) {
			dev_info(ts->dev, "venus-fts: 芯片就绪（第 %d 次轮询）\n", i);
			return 0;
		}
		if (ev[0] == FTS_EVT_ERROR)
			dev_warn(ts->dev, "venus-fts: 错误事件 [%*ph]\n",
				 FTS_EVENT_SIZE, ev);
		msleep(10);
	}

	return -ETIMEDOUT;
}

static int venus_fts_read_sysinfo(struct venus_fts *ts)
{
	u8 load[3] = { FTS_CMD_SYSTEM, FTS_SYS_CMD_LOAD_DATA, FTS_LOAD_SYS_INFO };
	u8 rd[3] = { FTS_CMD_FRAMEBUFFER_R, 0x00, 0x00 };
	u8 info[FTS_SYSINFO_SIZE];
	int ret;

	ret = venus_fts_write(ts, load, sizeof(load));
	if (ret)
		return ret;
	msleep(20);

	ret = venus_fts_xfer(ts, rd, sizeof(rd), info, sizeof(info));
	if (ret)
		return ret;

	/* 厂商校验：data[0] 是头部签名 0xA5，chip id 在 [10]=0x39 [11]=0x36 */
	if (info[0] != 0xa5)
		dev_warn(ts->dev, "venus-fts: sysinfo 签名异常 0x%02x\n", info[0]);

	dev_info(ts->dev,
		 "venus-fts: sysinfo 签名=0x%02x chipid=%02x%02x fwver=%02x.%02x 配置=%02x/%02x\n",
		 info[0], info[10], info[11], info[5], info[4], info[7], info[8]);

	return 0;
}

static int venus_fts_set_scan(struct venus_fts *ts, u8 mode, u8 settings)
{
	u8 cmd[3] = { FTS_CMD_SCAN_MODE, mode, settings };

	return venus_fts_write(ts, cmd, sizeof(cmd));
}

/* ---------- 事件上报 ---------- */

static void venus_fts_report_touch(struct venus_fts *ts, const u8 *ev)
{
	u8 id = (ev[1] & 0xf0) >> 4;
	u8 type = ev[1] & 0x0f;
	u16 x = ((ev[3] & 0x0f) << 8) | ev[2];
	u16 y = (ev[4] << 4) | ((ev[3] & 0xf0) >> 4);
	u8 major = ((ev[0] & 0x0c) << 2) | ((ev[6] & 0xf0) >> 4);
	u8 minor = ((ev[7] & 0xc0) >> 2) | (ev[6] & 0x0f);
	s8 angle = (s8)ev[5];

	if (id >= FTS_MAX_FINGERS)
		return;

	if (type == FTS_TOUCH_TYPE_HOVER) {
		input_report_abs(ts->input, ABS_X, x);
		input_report_abs(ts->input, ABS_Y, y);
		input_report_abs(ts->input, ABS_DISTANCE, 1);
		input_sync(ts->input);
		return;
	}

	if (type != FTS_TOUCH_TYPE_FINGER && type != FTS_TOUCH_TYPE_GLOVE)
		return;

	if (x > ts->x_max)
		x = ts->x_max;
	if (y > ts->y_max)
		y = ts->y_max;

	input_mt_slot(ts->input, id);
	input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
	input_report_abs(ts->input, ABS_MT_POSITION_X, x);
	input_report_abs(ts->input, ABS_MT_POSITION_Y, y);
	input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, major);
	input_report_abs(ts->input, ABS_MT_TOUCH_MINOR, minor);
	input_report_abs(ts->input, ABS_MT_ORIENTATION, angle);
	input_sync(ts->input);
}

static void venus_fts_report_release(struct venus_fts *ts, const u8 *ev)
{
	u8 id = (ev[1] & 0xf0) >> 4;

	if (id >= FTS_MAX_FINGERS)
		return;

	input_mt_slot(ts->input, id);
	input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
	input_sync(ts->input);
}

static void venus_fts_handle_events(struct venus_fts *ts)
{
	static u8 events[FTS_EVENT_SIZE * FTS_MAX_EVENTS];
	int count, i, ret;

	ret = venus_fts_read_all(ts, events, &count);
	if (ret) {
		dev_err(ts->dev, "venus-fts: 读事件失败 %d\n", ret);
		return;
	}

	for (i = 0; i < count; i++) {
		u8 *ev = &events[i * FTS_EVENT_SIZE];

		switch (ev[0]) {
		case FTS_EVT_ENTER_POINT:
		case FTS_EVT_MOTION_POINT:
			if (ts->log_budget > 0) {
				ts->log_budget--;
				dev_info(ts->dev, "venus-fts: 触摸事件 [%*ph]\n",
					 FTS_EVENT_SIZE, ev);
			}
			venus_fts_report_touch(ts, ev);
			break;
		case FTS_EVT_LEAVE_POINT:
			venus_fts_report_release(ts, ev);
			break;
		case FTS_EVT_ERROR:
			dev_warn(ts->dev, "venus-fts: 错误事件 [%*ph]\n",
				 FTS_EVENT_SIZE, ev);
			break;
		default:
			break;
		}
	}
}

static void venus_fts_poll(struct work_struct *work)
{
	struct venus_fts *ts = container_of(work, struct venus_fts, poll_work.work);

	mutex_lock(&ts->lock);
	if (ts->ready)
		venus_fts_handle_events(ts);
	mutex_unlock(&ts->lock);

	schedule_delayed_work(&ts->poll_work, msecs_to_jiffies(ts->poll_ms));
}

static irqreturn_t venus_fts_irq(int irq, void *data)
{
	struct venus_fts *ts = data;

	mutex_lock(&ts->lock);
	if (ts->ready)
		venus_fts_handle_events(ts);
	mutex_unlock(&ts->lock);

	return IRQ_HANDLED;
}

/* ---------- probe / remove ---------- */

static int venus_fts_probe(struct spi_device *spi)
{
	static const char * const supply_names[] = { "vdd", "avdd" };
	struct venus_fts *ts;
	struct device *dev = &spi->dev;
	int ret;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->spi = spi;
	ts->dev = dev;
	ts->x_max = 1439;
	ts->y_max = 3199;
	mutex_init(&ts->lock);

	ts->num_supplies = ARRAY_SIZE(supply_names);
	ts->supplies = devm_kcalloc(dev, ts->num_supplies,
				    sizeof(*ts->supplies), GFP_KERNEL);
	if (!ts->supplies)
		return -ENOMEM;
	for (ret = 0; ret < ts->num_supplies; ret++)
		ts->supplies[ret].supply = supply_names[ret];

	ret = devm_regulator_bulk_get(dev, ts->num_supplies, ts->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "取触摸电源失败\n");

	ts->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ts->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ts->reset_gpio), "取 reset gpio 失败\n");

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input)
		return -ENOMEM;

	ts->input->name = "venus-fts-ts";
	ts->input->id.bustype = BUS_SPI;
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, ts->x_max, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, ts->y_max, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MAJOR, 0, 4095, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MINOR, 0, 4095, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_ORIENTATION, -128, 127, 0, 0);
	input_set_abs_params(ts->input, ABS_X, 0, ts->x_max, 0, 0);
	input_set_abs_params(ts->input, ABS_Y, 0, ts->y_max, 0, 0);
	input_set_abs_params(ts->input, ABS_DISTANCE, 0, 1, 0, 0);
	input_set_capability(ts->input, EV_KEY, BTN_TOUCH);

	ret = input_mt_init_slots(ts->input, FTS_MAX_FINGERS, INPUT_MT_DIRECT);
	if (ret)
		return ret;

	spi_set_drvdata(spi, ts);

	/* 中断先申请但不自动使能：芯片没起来时 INT 常低会造成中断风暴 */
	ts->irq = spi->irq;
	ret = devm_request_threaded_irq(dev, ts->irq, NULL, venus_fts_irq,
					IRQF_ONESHOT | IRQF_NO_AUTOEN,
					"venus-fts", ts);
	if (ret)
		return dev_err_probe(dev, ret, "申请中断失败\n");

	venus_fts_power_cycle(ts);

	ret = venus_fts_wait_ready(ts);
	if (ret) {
		dev_err(dev, "venus-fts: 等不到 controller-ready，放弃注册中断\n");
		return ret;
	}

	venus_fts_read_sysinfo(ts);

	/* 厂商 fts_mode_handler 的 "Sense ON" 是 setScanMode(ACTIVE, 0x01)：
	 * settings=0x01 才真正开启扫描，0x00 只是保持寄存器值 */
	ret = venus_fts_set_scan(ts, FTS_SCAN_MODE_ACTIVE, 0x01);
	if (ret) {
		dev_err(dev, "venus-fts: 开扫描失败 %d\n", ret);
		return ret;
	}

	ret = input_register_device(ts->input);
	if (ret)
		return ret;

	mutex_lock(&ts->lock);
	ts->ready = true;
	mutex_unlock(&ts->lock);
	enable_irq(ts->irq);

	/*
	 * 正式版只走中断。轮询仅作调试手段（poll_ms>0 时启用），
	 * 因为中断已验证可用（/proc/interrupts 计数随触摸增长）。
	 */
	ts->log_budget = 0;
	ts->poll_ms = 0;
	INIT_DELAYED_WORK(&ts->poll_work, venus_fts_poll);

	dev_info(dev, "venus-fts: 触屏已启用（%s），中断驱动\n", ts->input->name);
	return 0;
}

static void venus_fts_remove(struct spi_device *spi)
{
	struct venus_fts *ts = spi_get_drvdata(spi);

	mutex_lock(&ts->lock);
	ts->ready = false;
	mutex_unlock(&ts->lock);

	cancel_delayed_work_sync(&ts->poll_work);
	disable_irq(ts->irq);
	venus_fts_set_scan(ts, 0x01 /* LOW_POWER */, 0x00);
	regulator_disable(ts->supplies[1].consumer);
	regulator_disable(ts->supplies[0].consumer);
}

static const struct of_device_id venus_fts_of_match[] = {
	{ .compatible = "st,venus-fts" },
	{ }
};
MODULE_DEVICE_TABLE(of, venus_fts_of_match);

static const struct spi_device_id venus_fts_spi_id[] = {
	{ "venus-fts", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, venus_fts_spi_id);

static struct spi_driver venus_fts_driver = {
	.probe = venus_fts_probe,
	.remove = venus_fts_remove,
	.id_table = venus_fts_spi_id,
	.driver = {
		.name = "venus-fts-ts",
		.of_match_table = venus_fts_of_match,
	},
};
module_spi_driver(venus_fts_driver);

MODULE_DESCRIPTION("ST FTS touchscreen for Xiaomi Mi 11 (venus), SPI");
MODULE_LICENSE("GPL");
