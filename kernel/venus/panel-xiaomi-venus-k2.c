// SPDX-License-Identifier: GPL-2.0-only
/*
 * Xiaomi Mi 11 (venus) 面板驱动 —— 三星 DDIC，"xiaomi 38 08 0a cmd mode dsc dsi panel"
 *
 * 参数与初始化序列来源：
 *   - 分辨率/时序/DSC：Android 运行时 DTB 里 qcom,mdss_dsi_k2_38_08_0a_mp_dsc_cmd
 *   - on/off 命令：同一节点的 qcom,mdss-dsi-on-command（按 msm 下游格式解析：
 *     每条 = dstype,last,vc,flags,wait,len_hi,len_lo,payload...）
 *   - 电源轨：vendor DTS 的 dsi_panel_pwr_supply_k2b（vddio 1.8V / vdd 3.0V / vddd 1.2V@gpio83）
 *   - reset: tlmm 24
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

#include <video/mipi_display.h>

struct venus_k2 {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct drm_dsc_config dsc;
	struct gpio_desc *reset_gpio;
	struct regulator_bulk_data *supplies;
};

/*
 * 面板三路电：vddio 1.8V、vdd 3.0V（PMIC LDO），vddd 1.2V（GPIO83 控制的 fixed regulator）。
 * 厂商 DTS 里 vddd 是挂在 sde_dsi 上的 display_panel_vddd，缺它面板逻辑不上电 → 全黑无背光。
 */
static const struct regulator_bulk_data venus_k2_supplies[] = {
	{ .supply = "vddio" },
	{ .supply = "vdd" },
	{ .supply = "vddd" },
};

/*
 * 厂商 DSC 参数（从 Android 运行时 DTB 的 qcom,mdss-dsi-on-command 里那条
 * 0x9E 命令解析出来，832 字节序列共 73 条命令）。直接发原厂 128 字节 PPS，
 * 保证解码端参数与厂商固件完全一致；同时把同样的数值填进 drm_dsc_config，
 * 让 DSI/DPU 的编码器按同一套参数压缩。
 *
 * 关键值：10bpc / 8bpp / linebuf 9 / slice 720x50 / 2 slice / convert_rgb=1 / block_pred=1
 */
struct venus_k2_cmd {
	u8 type;		/* 0x05=DCS短写, 0x15=DCS短写+1参, 0x39=DCS长写 */
	u8 wait;		/* 发送后等待的毫秒数 */
	u16 len;		/* payload 长度（含首字节命令码） */
	u8 data[130];
};

/* 厂商 K2 面板初始化序列（73 条，直接从 Android 运行时 DTB 解析；
 * 每条格式: {dstype, wait_ms, len, payload...}，dstype 0x05=DCS短写0参,
 * 0x15=DCS短写1参, 0x39=DCS长写。 */
static const struct venus_k2_cmd venus_k2_on_seq[] = {
	{ 0x15, 0, 2, { 0x9d, 0x01 } },
	{ 0x39, 0, 129, { 0x9e, 0x11, 0x00, 0x00, 0xa9, 0x30, 0x80, 0x0c, 0x80, 0x05, 0xa0, 0x00, 0x32, 0x02, 0xd0, 0x02, 0xd0, 0x02, 0x00, 0x02, 0x68, 0x00, 0x20, 0x05, 0x8c, 0x00, 0x0a, 0x00, 0x0c, 0x01, 0xf6, 0x01, 0x87, 0x18, 0x00, 0x10, 0xf0, 0x03, 0x0c, 0x20, 0x00, 0x06, 0x0b, 0x0b, 0x33, 0x0e, 0x1c, 0x2a, 0x38, 0x46, 0x54, 0x62, 0x69, 0x70, 0x77, 0x79, 0x7b, 0x7d, 0x7e, 0x01, 0x02, 0x01, 0x00, 0x09, 0x40, 0x09, 0xbe, 0x19, 0xfc, 0x19, 0xfa, 0x19, 0xf8, 0x1a, 0x38, 0x1a, 0x78, 0x1a, 0xb6, 0x2a, 0xf6, 0x2b, 0x34, 0x2b, 0x74, 0x3b, 0x74, 0x6b, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
	{ 0x05, 10, 2, { 0x11, 0x00 } },
	{ 0x15, 0, 2, { 0x35, 0x00 } },
	{ 0x39, 0, 5, { 0x2a, 0x00, 0x00, 0x05, 0x9f } },
	{ 0x39, 0, 5, { 0x2b, 0x00, 0x00, 0x0c, 0x7f } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x01 } },
	{ 0x15, 0, 2, { 0xb4, 0x01 } },
	{ 0x15, 0, 2, { 0xf7, 0x07 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x02 } },
	{ 0x39, 0, 5, { 0xf4, 0x00, 0xc0, 0x7f, 0x3d } },
	{ 0x15, 0, 2, { 0xb0, 0x09 } },
	{ 0x15, 0, 2, { 0xf4, 0x07 } },
	{ 0x15, 0, 2, { 0xb0, 0x11 } },
	{ 0x15, 0, 2, { 0xf4, 0x19 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x04 } },
	{ 0x15, 0, 2, { 0xee, 0x80 } },
	{ 0x15, 0, 2, { 0xb0, 0xc0 } },
	{ 0x15, 0, 2, { 0xd6, 0x40 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 8, { 0xb3, 0x00, 0x00, 0xd8, 0xd8, 0xff, 0xff, 0x40 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xe7, 0x81 } },
	{ 0x15, 0, 2, { 0xb0, 0x09 } },
	{ 0x15, 0, 2, { 0xe7, 0x03 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 3, { 0xfc, 0x5a, 0x5a } },
	{ 0x39, 0, 2, { 0xb0, 0x0f } },
	{ 0x39, 0, 2, { 0xe1, 0x10 } },
	{ 0x39, 0, 2, { 0xcf, 0x01 } },
	{ 0x39, 0, 3, { 0xfc, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 3, { 0xfc, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x76 } },
	{ 0x15, 0, 2, { 0xd1, 0x01 } },
	{ 0x15, 0, 2, { 0xb0, 0x22 } },
	{ 0x39, 0, 4, { 0xe2, 0x01, 0x02, 0x25 } },
	{ 0x15, 0, 2, { 0xf7, 0x07 } },
	{ 0x39, 0, 3, { 0xfc, 0xa5, 0xa5 } },
	{ 0x39, 90, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x0d } },
	{ 0x15, 0, 2, { 0xb4, 0x20 } },
	{ 0x15, 0, 2, { 0xb0, 0x0c } },
	{ 0x15, 0, 2, { 0xb4, 0x20 } },
	{ 0x15, 0, 2, { 0x53, 0x20 } },
	{ 0x39, 0, 3, { 0x51, 0x00, 0x00 } },
	{ 0x15, 0, 2, { 0xf7, 0x07 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 3, { 0xfc, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x07 } },
	{ 0x39, 0, 4, { 0xeb, 0x03, 0x88, 0xf8 } },
	{ 0x39, 0, 3, { 0xfc, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x05, 17, 2, { 0x29, 0x00 } },
	{ 0x15, 0, 2, { 0x60, 0x08 } },
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 3, { 0xfc, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0xb0, 0x55 } },
	{ 0x15, 0, 2, { 0xd1, 0x0e } },
	{ 0x15, 0, 2, { 0xf7, 0x07 } },
	{ 0x39, 0, 3, { 0xfc, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
};

/* 厂商关屏序列（含 sleep in） */
static const struct venus_k2_cmd venus_k2_off_seq[] = {
	{ 0x39, 0, 3, { 0xf0, 0x5a, 0x5a } },
	{ 0x39, 0, 3, { 0xfc, 0x5a, 0x5a } },
	{ 0x15, 0, 2, { 0x60, 0x08 } },
	{ 0x15, 0, 2, { 0xb0, 0x55 } },
	{ 0x15, 0, 2, { 0xd1, 0x0e } },
	{ 0x15, 0, 2, { 0x53, 0x28 } },
	{ 0x15, 0, 2, { 0xf7, 0x07 } },
	{ 0x39, 0, 3, { 0xfc, 0xa5, 0xa5 } },
	{ 0x39, 0, 3, { 0xf0, 0xa5, 0xa5 } },
	{ 0x05, 34, 2, { 0x28, 0x00 } },
	{ 0x05, 120, 2, { 0x10, 0x00 } },
};

static const u8 venus_k2_pps[128] = {
	0x11, 0x00, 0x00, 0xa9, 0x30, 0x80, 0x0c, 0x80, 0x05, 0xa0, 0x00, 0x32,
	0x02, 0xd0, 0x02, 0xd0, 0x02, 0x00, 0x02, 0x68, 0x00, 0x20, 0x05, 0x8c,
	0x00, 0x0a, 0x00, 0x0c, 0x01, 0xf6, 0x01, 0x87, 0x18, 0x00, 0x10, 0xf0,
	0x03, 0x0c, 0x20, 0x00, 0x06, 0x0b, 0x0b, 0x33, 0x0e, 0x1c, 0x2a, 0x38,
	0x46, 0x54, 0x62, 0x69, 0x70, 0x77, 0x79, 0x7b, 0x7d, 0x7e, 0x01, 0x02,
	0x01, 0x00, 0x09, 0x40, 0x09, 0xbe, 0x19, 0xfc, 0x19, 0xfa, 0x19, 0xf8,
	0x1a, 0x38, 0x1a, 0x78, 0x1a, 0xb6, 0x2a, 0xf6, 0x2b, 0x34, 0x2b, 0x74,
	0x3b, 0x74, 0x6b, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

static bool video_mode;
module_param(video_mode, bool, 0644);
MODULE_PARM_DESC(video_mode, "1=视频模式（无 DSC，30Hz），用于验证刷新通路");

static inline struct venus_k2 *to_venus_k2(struct drm_panel *panel)
{
	return container_of(panel, struct venus_k2, panel);
}

static void venus_k2_reset(struct venus_k2 *ctx)
{
	/*
	 * GPIO24 = LCD_RESET_N（active-low）。
	 * 厂商 DT 的 reset-sequence 是 <0 10 1 10>：拉低 10ms 再放开 10ms。
	 * 之前这里多了一次 set(1) 收尾，等于把面板一直按在复位里 —— 表现为
	 * 写入不报错、DCS 回读全部超时（-110）、屏不亮背光不亮。
	 */
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);	/* 复位有效 */
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);	/* 释放复位 */
	usleep_range(10000, 11000);
}

static int venus_k2_send_seq(struct venus_k2 *ctx, const struct venus_k2_cmd *seq,
			     size_t count)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	int i, ret;

	for (i = 0; i < count; i++) {
		const struct venus_k2_cmd *c = &seq[i];

		if (!c->len)
			continue;

		/* 原厂序列里那条 0x9E + 128 字节 PPS 跳过：PPS 必须与 msm 的
		 * dsi_populate_dsc_params() 算出的硬件配置一致，所以由下面
		 * venus_k2_send_pps() 单独发。 */
		if (c->type == 0x39 && c->data[0] == 0x9e)
			continue;

		switch (c->type) {
		case 0x05:	/* DCS 短写，无参数 */
			ret = mipi_dsi_dcs_write(dsi, c->data[0], NULL, 0);
			break;
		case 0x15:	/* DCS 短写，1 个参数 */
		case 0x39:	/* DCS 长写 */
			ret = mipi_dsi_dcs_write(dsi, c->data[0], &c->data[1],
						 c->len - 1);
			break;
		default:
			ret = mipi_dsi_generic_write(dsi, c->data, c->len);
			break;
		}

		if (ret < 0) {
			dev_err(&dsi->dev, "venus-k2: 第 %d 条命令(type 0x%02x, cmd 0x%02x)失败: %d\n",
				i, c->type, c->data[0], ret);
			return ret;
		}

		if (c->wait)
			msleep(c->wait);
	}

	return 0;
}

/* 与 msm dsi_populate_dsc_params() 完全相同的补全顺序，
 * 保证我们发出去的 PPS 与 DSI/DSC 硬件寄存器一致。 */
static void venus_k2_complete_dsc(struct venus_k2 *ctx)
{
	struct drm_dsc_config *dsc = &ctx->dsc;

	dsc->simple_422 = 0;
	dsc->convert_rgb = 1;
	dsc->vbr_enable = 0;

	drm_dsc_set_const_params(dsc);
	drm_dsc_set_rc_buf_thresh(dsc);
	drm_dsc_setup_rc_params(dsc, DRM_DSC_1_1_PRE_SCR);
	dsc->initial_scale_value = drm_dsc_initial_scale_value(dsc);
	dsc->line_buf_depth = dsc->bits_per_component + 1;
	drm_dsc_compute_rc_parameters(dsc);
}

static int venus_k2_send_pps(struct venus_k2 *ctx)
{
	struct drm_dsc_picture_parameter_set pps;
	char buf[3 * 128 + 1];
	int i, ret;

	venus_k2_complete_dsc(ctx);
	drm_dsc_pps_payload_pack(&pps, &ctx->dsc);

	for (i = 0; i < 128; i++)
		snprintf(buf + i * 3, 4, "%02x ", ((u8 *)&pps)[i]);
	dev_info(&ctx->dsi->dev, "venus-k2: 发送的 PPS:\n%s\n", buf);

	ret = mipi_dsi_picture_parameter_set(ctx->dsi, &pps);
	if (ret < 0)
		return ret;

	return mipi_dsi_compression_mode(ctx->dsi, true);
}

static int venus_k2_on(struct venus_k2 *ctx)
{
	return venus_k2_send_seq(ctx, venus_k2_on_seq,
				 ARRAY_SIZE(venus_k2_on_seq));
}

static int venus_k2_off(struct venus_k2 *ctx)
{
	return venus_k2_send_seq(ctx, venus_k2_off_seq,
				 ARRAY_SIZE(venus_k2_off_seq));
}

static int venus_k2_prepare(struct drm_panel *panel)
{
	struct venus_k2 *ctx = to_venus_k2(panel);
	struct device *dev = &ctx->dsi->dev;
	struct drm_dsc_picture_parameter_set pps;
	u8 pm = 0, ddb[3] = { 0 };
	int ret;

	dev_info(dev, "venus-k2: prepare 开始\n");

	ret = regulator_bulk_enable(ARRAY_SIZE(venus_k2_supplies), ctx->supplies);
	dev_info(dev, "venus-k2: 电源 rc=%d\n", ret);
	if (ret < 0)
		return ret;

	venus_k2_reset(ctx);
	dev_info(dev, "venus-k2: reset 完成\n");

	if (!video_mode) {
		ret = venus_k2_send_pps(ctx);
		dev_info(dev, "venus-k2: PPS + 压缩模式 rc=%d\n", ret);
	}
	ret = venus_k2_on(ctx);
	dev_info(dev, "venus-k2: on 序列 rc=%d\n", ret);
	if (ret < 0) {
		dev_err(dev, "面板初始化失败: %d\n", ret);
		regulator_bulk_disable(ARRAY_SIZE(venus_k2_supplies), ctx->supplies);
		return ret;
	}

	msleep(30);

	/* 诊断：读回 DCS 寄存器，确认面板真的在应答 */
	ret = mipi_dsi_dcs_read(ctx->dsi, MIPI_DCS_GET_POWER_MODE, &pm, 1);
	dev_info(dev, "venus-k2: 读 power_mode rc=%d val=0x%02x\n", ret, pm);
	ret = mipi_dsi_dcs_read(ctx->dsi, MIPI_DCS_READ_DDB_START, ddb, 3);
	dev_info(dev, "venus-k2: 读 DDB rc=%d [%02x %02x %02x]\n", ret, ddb[0], ddb[1], ddb[2]);

	return 0;
}

static int venus_k2_unprepare(struct drm_panel *panel)
{
	struct venus_k2 *ctx = to_venus_k2(panel);

	venus_k2_off(ctx);
	regulator_bulk_disable(ARRAY_SIZE(venus_k2_supplies), ctx->supplies);

	return 0;
}


/*
 * 1440x3200@120Hz，porches 取自厂商 DTB（hfp/hbp/hpw=32，vbp=32/vfp=24/vpw=24）。
 * 命令模式下 drm 用这个 mode 计算 MDP 时序和 DSI 时钟。
 */
static const struct drm_display_mode venus_k2_mode = {
	.clock = (1440 + 32 + 32 + 32) * (3200 + 32 + 24 + 24) * 120 / 1000,
	.hdisplay = 1440,
	.hsync_start = 1440 + 32,
	.hsync_end = 1440 + 32 + 32,
	.htotal = 1440 + 32 + 32 + 32,
	.vdisplay = 3200,
	.vsync_start = 3200 + 24,
	.vsync_end = 3200 + 24 + 24,
	.vtotal = 3200 + 24 + 24 + 32,
	.width_mm = 70,
	.height_mm = 156,
};

/* 视频模式（无 DSC）用的 30Hz 模式，pclk 落在 4 lane 可承受范围 */
static const struct drm_display_mode venus_k2_mode_30 = {
	.clock = (1440 + 32 + 32 + 32) * (3200 + 32 + 24 + 24) * 30 / 1000,
	.hdisplay = 1440,
	.hsync_start = 1440 + 32,
	.hsync_end = 1440 + 32 + 32,
	.htotal = 1440 + 32 + 32 + 32,
	.vdisplay = 3200,
	.vsync_start = 3200 + 24,
	.vsync_end = 3200 + 24 + 24,
	.vtotal = 3200 + 24 + 24 + 32,
	.width_mm = 70,
	.height_mm = 156,
};

static int venus_k2_get_modes(struct drm_panel *panel,
			      struct drm_connector *connector)
{
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev,
				  video_mode ? &venus_k2_mode_30 : &venus_k2_mode);
	if (!mode)
		return -ENOMEM;

	mode->type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	drm_mode_set_name(mode);
	drm_mode_probed_add(connector, mode);

	connector->display_info.width_mm = 70;
	connector->display_info.height_mm = 156;

	return 1;
}

static const struct drm_panel_funcs venus_k2_panel_funcs = {
	.prepare = venus_k2_prepare,
	.unprepare = venus_k2_unprepare,
	.get_modes = venus_k2_get_modes,
};

static int venus_k2_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness = backlight_get_brightness(bl);
	int ret;

	/*
	 * 亮度是 11bit（厂商 bl-max-level=2047）。
	 * 实测：写 2047 = 最亮、写 0 = 关屏，所以是正向映射。
	 * （DT 里的 qcom,mdss-dsi-bl-inverted-dbv 是"厂商在 HAL 层取反"，内核这里不能照做。）
	 */
	brightness = brightness * 2047 / 255;

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;
	ret = mipi_dsi_dcs_set_display_brightness(dsi, brightness);
	if (ret < 0)
		return ret;
	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	return 0;
}

static const struct backlight_ops venus_k2_bl_ops = {
	.update_status = venus_k2_bl_update_status,
};

static struct backlight_device *
venus_k2_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = 153,	/* 开机 60% */
		.max_brightness = 255,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &venus_k2_bl_ops, &props);
}

static int venus_k2_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct venus_k2 *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct venus_k2, panel,
				   &venus_k2_panel_funcs, DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ret = devm_regulator_bulk_get_const(dev, ARRAY_SIZE(venus_k2_supplies),
					    venus_k2_supplies, &ctx->supplies);
	if (ret < 0)
		return dev_err_probe(dev, ret, "取面板电源失败\n");

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio), "取 reset gpio 失败\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	/*
	 * 命令模式面板（实测可用）。改成视频模式会报 DSI FIFO 错误
	 * （dsi_err_worker: status=4 = DSI_ERR_STATE_FIFO），面板不接受视频流，
	 * 所以必须保持命令模式。
	 */
	if (video_mode)
		dsi->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_SYNC_PULSE |
				  MIPI_DSI_MODE_NO_EOT_PACKET;
	else
		dsi->mode_flags = MIPI_DSI_MODE_NO_EOT_PACKET |
				  MIPI_DSI_CLOCK_NON_CONTINUOUS;

	ctx->panel.prepare_prev_first = true;
	ctx->panel.backlight = venus_k2_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight), "注册背光失败\n");

	ret = drm_panel_of_backlight(&ctx->panel);
	if (ret)
		return ret;

	drm_panel_add(&ctx->panel);

	/* 面板只支持 DSC：参数取自厂商 DTB（10bpc / 8bpp / slice 720x50） */
	if (!video_mode)
		dsi->dsc = &ctx->dsc;
	ctx->dsc.dsc_version_major = 1;
	ctx->dsc.dsc_version_minor = 1;
	ctx->dsc.pic_width = 1440;
	ctx->dsc.pic_height = 3200;
	ctx->dsc.slice_height = 50;
	ctx->dsc.slice_width = 720;
	ctx->dsc.slice_count = 2;
	ctx->dsc.bits_per_component = 10;
	ctx->dsc.bits_per_pixel = 8 << 4;	/* 4 位小数 */
	ctx->dsc.block_pred_enable = true;
	ctx->dsc.line_buf_depth = 9;
	ctx->dsc.convert_rgb = true;
	/* 以下 RC 参数同样取自原厂 PPS */
	ctx->dsc.initial_xmit_delay = 512;
	ctx->dsc.initial_dec_delay = 616;
	ctx->dsc.initial_scale_value = 32;
	ctx->dsc.scale_increment_interval = 1420;
	ctx->dsc.scale_decrement_interval = 10;
	ctx->dsc.first_line_bpg_offset = 12;
	ctx->dsc.nfl_bpg_offset = 502;
	ctx->dsc.slice_bpg_offset = 391;
	ctx->dsc.initial_offset = 6144;
	ctx->dsc.final_offset = 4336;
	ctx->dsc.flatness_min_qp = 3;
	ctx->dsc.flatness_max_qp = 12;
	ctx->dsc.rc_model_size = 8192;
	ctx->dsc.rc_edge_factor = 6;
	ctx->dsc.rc_quant_incr_limit0 = 11;
	ctx->dsc.rc_quant_incr_limit1 = 11;
	ctx->dsc.rc_tgt_offset_high = 3;
	ctx->dsc.rc_tgt_offset_low = 3;
	ctx->dsc.native_422 = false;
	ctx->dsc.native_420 = false;

	/* 让内核按同一套公式补全 rc_range_parameters 等派生字段：
	 * 编码器寄存器与 PPS 必须来自同一份配置，否则面板解出来就是花屏。 */
	{
		int rc = drm_dsc_setup_rc_params(&ctx->dsc, DRM_DSC_1_1_PRE_SCR);

		dev_info(dev, "venus-k2: drm_dsc_setup_rc_params rc=%d\n", rc);
	}

	{
		struct drm_dsc_picture_parameter_set pps_t;
		char buf[3 * 128 + 1];
		int i;

		drm_dsc_pps_payload_pack(&pps_t, &ctx->dsc);
		for (i = 0; i < 128; i++)
			snprintf(buf + i * 3, 4, "%02x ", ((u8 *)&pps_t)[i]);
		dev_info(dev, "venus-k2: 我们生成的 PPS 十六进制:\n%s\n", buf);
	}

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "mipi_dsi_attach 失败\n");
	}

	return 0;
}

static void venus_k2_remove(struct mipi_dsi_device *dsi)
{
	struct venus_k2 *ctx = mipi_dsi_get_drvdata(dsi);

	mipi_dsi_detach(dsi);
	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id venus_k2_of_match[] = {
	{ .compatible = "xiaomi,venus-k2" },
	{ }
};
MODULE_DEVICE_TABLE(of, venus_k2_of_match);

static struct mipi_dsi_driver venus_k2_driver = {
	.probe = venus_k2_probe,
	.remove = venus_k2_remove,
	.driver = {
		.name = "panel-xiaomi-venus-k2",
		.of_match_table = venus_k2_of_match,
	},
};
module_mipi_dsi_driver(venus_k2_driver);

MODULE_DESCRIPTION("Xiaomi Mi 11 (venus) K2 AMOLED DSI panel");
MODULE_LICENSE("GPL");
