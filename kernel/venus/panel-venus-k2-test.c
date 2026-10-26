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
#include <linux/delay.h>
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

static inline struct venus_k2 *to_venus_k2(struct drm_panel *panel)
{
	return container_of(panel, struct venus_k2, panel);
}

static void venus_k2_reset(struct venus_k2 *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
}

/* 三星 DDIC 的页/级别选择：B0 A5 00 */
static int venus_k2_page(struct venus_k2 *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0xb0, 0xa5, 0x00);
	return dsi_ctx.accum_err;
}

static int venus_k2_on(struct venus_k2 *ctx)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };
	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	/* 厂商序列：页选 -> 面板内部配置 -> 睡醒 -> 亮屏 */
	mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0xb0, 0xa5, 0x00);
	mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0x5c, 0x42, 0x00);
	venus_k2_page(ctx);
	mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0xf8, 0x00, 0x08, 0x10, 0x08, 0x2d, 0x00, 0x00, 0x2d);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x55, 0x08);

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_EXIT_SLEEP_MODE);
	mipi_dsi_msleep(&dsi_ctx, 30);

	venus_k2_page(ctx);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xe0, 0x18);
	mipi_dsi_generic_write_seq_multi(&dsi_ctx, 0xc0, 0x00, 0x53, 0x6f, 0x51,
					 0x50, 0x51, 0x34, 0x4f, 0x5a, 0x33, 0x19);

	/* 0x35 = write_memory_start（面板要求亮屏前发一次） */
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_WRITE_MEMORY_START);
	mipi_dsi_msleep(&dsi_ctx, 120);

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_SET_DISPLAY_ON);
	mipi_dsi_msleep(&dsi_ctx, 60);

	return dsi_ctx.accum_err;
}

static int venus_k2_off(struct venus_k2 *ctx)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_SET_DISPLAY_OFF);
	mipi_dsi_msleep(&dsi_ctx, 20);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_ENTER_SLEEP_MODE);
	mipi_dsi_msleep(&dsi_ctx, 120);

	return dsi_ctx.accum_err;
}

static int venus_k2_prepare(struct drm_panel *panel)
{
	struct venus_k2 *ctx = to_venus_k2(panel);
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(venus_k2_supplies), ctx->supplies);
	if (ret < 0) {
		dev_err(dev, "使能面板电源失败: %d\n", ret);
		return ret;
	}

	venus_k2_reset(ctx);

	ret = venus_k2_on(ctx);
	if (ret < 0) {
		dev_err(dev, "面板初始化失败: %d\n", ret);
		regulator_bulk_disable(ARRAY_SIZE(venus_k2_supplies), ctx->supplies);
		return ret;
	}

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

static int venus_k2_get_modes(struct drm_panel *panel,
			      struct drm_connector *connector)
{
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &venus_k2_mode);
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

	/* 面板亮度是 11bit（0..2047，厂商 bl-max-level=2047） */
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
		.brightness = 255,
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

	struct drm_dsc_picture_parameter_set pps;
	struct regulator_bulk_data *sup;
	struct gpio_desc *rst;
	u8 pm = 0, ddb[3] = { 0 };
	int rv;
	int rc;

	sup = devm_kcalloc(dev, ARRAY_SIZE(venus_k2_supplies), sizeof(*sup), GFP_KERNEL);
	if (!sup)
		return -ENOMEM;
	for (rc = 0; rc < ARRAY_SIZE(venus_k2_supplies); rc++) {
		sup[rc].supply = venus_k2_supplies[rc].supply;
	}
	rc = devm_regulator_bulk_get(dev, ARRAY_SIZE(venus_k2_supplies), sup);
	if (rc < 0)
		return dev_err_probe(dev, rc, "取面板电源失败\n");

	rst = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(rst))
		return dev_err_probe(dev, PTR_ERR(rst), "取 reset gpio 失败\n");

	ctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	ctx->dsi = dsi;
	ctx->reset_gpio = rst;
	ctx->supplies = sup;

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_NO_EOT_PACKET | MIPI_DSI_CLOCK_NON_CONTINUOUS;

	/* 必须先 attach，否则 DSI host 未连接，所有 DCS 传输都会返回 -EINVAL */
	rc = mipi_dsi_attach(dsi);
	dev_info(dev, "探针: attach rc=%d\n", rc);
	if (rc < 0)
		return rc;

	rc = regulator_bulk_enable(ARRAY_SIZE(venus_k2_supplies), sup);
	dev_info(dev, "探针: 电源 enable rc=%d\n", rc);
	msleep(20);

	venus_k2_reset(ctx);
	dev_info(dev, "探针: reset 时序已发\n");

	rc = venus_k2_on(ctx);
	dev_info(dev, "探针: on 序列 rc=%d\n", rc);
	msleep(30);

	ctx->dsc.dsc_version_major = 1;
	ctx->dsc.dsc_version_minor = 1;
	ctx->dsc.slice_height = 50;
	ctx->dsc.slice_width = 720;
	ctx->dsc.slice_count = 2;
	ctx->dsc.bits_per_component = 10;
	ctx->dsc.bits_per_pixel = 8 << 4;
	ctx->dsc.block_pred_enable = true;
	ctx->dsc.line_buf_depth = 10;
	drm_dsc_pps_payload_pack(&pps, &ctx->dsc);
	rc = mipi_dsi_picture_parameter_set(dsi, &pps);
	dev_info(dev, "探针: PPS rc=%d\n", rc);

	rc = mipi_dsi_dcs_read(dsi, MIPI_DCS_GET_POWER_MODE, &pm, 1);
	dev_info(dev, "探针: 读 power_mode rc=%d val=0x%02x\n", rc, pm);

	rc = mipi_dsi_dcs_read(dsi, MIPI_DCS_READ_DDB_START, ddb, 3);
	dev_info(dev, "探针: 读 DDB rc=%d [%02x %02x %02x]\n", rc, ddb[0], ddb[1], ddb[2]);

	rv = mipi_dsi_dcs_read(dsi, 0xda, ddb, 3);
	dev_info(dev, "探针: 读 0xda rc=%d [%02x %02x %02x]\n", rv, ddb[0], ddb[1], ddb[2]);

	regulator_bulk_disable(ARRAY_SIZE(venus_k2_supplies), sup);
	mipi_dsi_detach(dsi);
	dev_info(dev, "探针: 完成（诊断模块不绑定设备）\n");
	return -ENODEV;

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	/* 命令模式面板：不用 VIDEO 标志，靠 MDP vsync 当 TE */
	dsi->mode_flags = MIPI_DSI_MODE_NO_EOT_PACKET | MIPI_DSI_CLOCK_NON_CONTINUOUS;

	ctx->panel.prepare_prev_first = true;
	ctx->panel.backlight = venus_k2_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight), "注册背光失败\n");

	ret = drm_panel_of_backlight(&ctx->panel);
	if (ret)
		return ret;

	drm_panel_add(&ctx->panel);

	/* 面板只支持 DSC：参数取自厂商 DTB（10bpc / 8bpp / slice 720x50） */
	dsi->dsc = &ctx->dsc;
	ctx->dsc.dsc_version_major = 1;
	ctx->dsc.dsc_version_minor = 1;
	ctx->dsc.slice_height = 50;
	ctx->dsc.slice_width = 720;
	ctx->dsc.slice_count = 1440 / 720;
	ctx->dsc.bits_per_component = 10;
	ctx->dsc.bits_per_pixel = 8 << 4;	/* 4 位小数 */
	ctx->dsc.block_pred_enable = true;
	ctx->dsc.line_buf_depth = 10;

	ret = -ENODEV;
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
		.name = "panel-venus-k2-test",
		.of_match_table = venus_k2_of_match,
	},
};
module_mipi_dsi_driver(venus_k2_driver);

MODULE_DESCRIPTION("Xiaomi Mi 11 (venus) K2 面板诊断探针（不绑定）");
MODULE_LICENSE("GPL");
