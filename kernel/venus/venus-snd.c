// SPDX-License-Identifier: GPL-2.0
/*
 * Xiaomi Mi 11 (venus) 声卡：QDSP6(APR) 的 TERT TDM RX0/RX1 接两颗 CS35L41 功放。
 *
 * 数据通路（取自厂商内核 techpack/audio/asoc/lahaina.c）：
 *   扬声器左 = Tertiary TDM RX0 → cs35l41_1 (@0x40)
 *   扬声器右 = Tertiary TDM RX1 → cs35l41_2 (@0x42)
 *
 * 卡本身由 qcom_snd_parse_of() 按设备树的 dai-link 描述搭建，这里只补两件事：
 *   1) BE 的 hw_params 固定 48kHz/2ch（DSP 侧 TDM 只跑这个配置）；
 *   2) 给 CS35L41 设 sysclk = BCLK（48k × 32bit = 1.536MHz，cs35l41 内部 PLL 表里有），
 *      做法与主线 AMD acp5x 机器驱动一致（cs35l41 在 ASP 模式没有单独 MCLK）。
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <sound/soc.h>
#include <sound/soc-dapm.h>
#include <sound/pcm.h>

#include "common.h"

#define VENUS_CS35L41_COMP	"cs35l41-codec"
#define VENUS_DEFAULT_RATE	48000
#define VENUS_SLOT_WIDTH	32
#define VENUS_TDM_SLOTS		4	/* 厂商 TDM_MAX_SLOTS=4，32bit/槽 → BCLK 6.144MHz */

static int venus_be_hw_params_fixup(struct snd_soc_pcm_runtime *rtd,
				    struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate = hw_param_interval(params,
					SNDRV_PCM_HW_PARAM_RATE);
	struct snd_interval *channels = hw_param_interval(params,
					SNDRV_PCM_HW_PARAM_CHANNELS);

	rate->min = rate->max = VENUS_DEFAULT_RATE;
	channels->min = channels->max = 2;

	return 0;
}

static int venus_be_hw_params(struct snd_pcm_substream *substream,
			      struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	struct snd_soc_component *comp;
	unsigned int bclk = params_rate(params) * VENUS_TDM_SLOTS * VENUS_SLOT_WIDTH;
	int i, ret;

	/* TDM 槽位配置必须给 DSP：不给的话 AFE enable 会返回 -22（port 0x9020 无效参数） */
	ret = snd_soc_dai_set_tdm_slot(cpu_dai, 0, 0xF, VENUS_TDM_SLOTS,
				       VENUS_SLOT_WIDTH);
	if (ret) {
		dev_err(cpu_dai->dev, "set_tdm_slot failed: %d\n", ret);
		return ret;
	}

	for_each_rtd_components(rtd, i, comp) {
		if (strcmp(comp->name, VENUS_CS35L41_COMP))
			continue;

		ret = snd_soc_component_set_sysclk(comp, 0, 0, bclk,
						   SND_SOC_CLOCK_IN);
		if (ret) {
			dev_err(comp->dev, "failed to set SYSCLK %u: %d\n",
				bclk, ret);
			return ret;
		}
	}

	return 0;
}

static const struct snd_soc_ops venus_be_ops = {
	.hw_params = venus_be_hw_params,
};

static void venus_add_be_ops(struct snd_soc_card *card)
{
	struct snd_soc_dai_link *link;
	int i;

	for_each_card_prelinks(card, i, link) {
		if (link->no_pcm == 1) {
			link->be_hw_params_fixup = venus_be_hw_params_fixup;
			link->ops = &venus_be_ops;
		}
	}
}

static int venus_snd_probe(struct platform_device *pdev)
{
	struct snd_soc_card *card;
	struct device *dev = &pdev->dev;
	int ret;

	card = devm_kzalloc(dev, sizeof(*card), GFP_KERNEL);
	if (!card)
		return -ENOMEM;

	card->owner = THIS_MODULE;
	card->dev = dev;
	card->driver_name = "venus";
	dev_set_drvdata(dev, card);

	ret = qcom_snd_parse_of(card);
	if (ret)
		return ret;

	venus_add_be_ops(card);

	return devm_snd_soc_register_card(dev, card);
}

static const struct of_device_id venus_snd_dt_match[] = {
	{ .compatible = "xiaomi,venus-sndcard" },
	{}
};
MODULE_DEVICE_TABLE(of, venus_snd_dt_match);

static struct platform_driver venus_snd_driver = {
	.probe = venus_snd_probe,
	.driver = {
		.name = "venus-snd",
		.of_match_table = venus_snd_dt_match,
	},
};
module_platform_driver(venus_snd_driver);

MODULE_DESCRIPTION("Xiaomi Mi 11 (venus) sound card");
MODULE_LICENSE("GPL");
