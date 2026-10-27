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

#include "qdsp6/q6afe.h"
#include "common.h"

#define VENUS_CS35L41_COMP	"cs35l41-codec"
#define VENUS_DEFAULT_RATE	48000
#define VENUS_SLOT_WIDTH	32
/* 可调参数：方便在不重编驱动的情况下试不同 TDM 组合（AFE 接受哪种由 DSP 决定） */
static int tdm_slots = 4;
module_param(tdm_slots, int, 0644);
static int tdm_slot_width = 32;
module_param(tdm_slot_width, int, 0644);
static int tdm_channels = 2;
module_param(tdm_channels, int, 0644);
static int tdm_mask = 0xF;
module_param(tdm_mask, int, 0644);

static int venus_be_hw_params_fixup(struct snd_soc_pcm_runtime *rtd,
				    struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate = hw_param_interval(params,
					SNDRV_PCM_HW_PARAM_RATE);
	struct snd_interval *channels = hw_param_interval(params,
					SNDRV_PCM_HW_PARAM_CHANNELS);

	rate->min = rate->max = VENUS_DEFAULT_RATE;
	channels->min = channels->max = tdm_channels;

	return 0;
}

/*
 * 上游 sm8250 的机器驱动在 startup 里给 CPU DAI 设 LPASS 时钟（IBIT）和 fmt。
 * TDM 同理：不设 Q6AFE_LPASS_CLK_ID_TER_TDM_IBIT，DSP 会以 -22 拒绝 AFE enable。
 */
static int venus_be_startup(struct snd_pcm_substream *substream)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	struct snd_soc_dai *codec_dai = snd_soc_rtd_to_codec(rtd, 0);
	unsigned int bclk = VENUS_DEFAULT_RATE * tdm_slots * tdm_slot_width;
	int ret;

	switch (cpu_dai->id) {
	case TERTIARY_TDM_RX_0:
	case TERTIARY_TDM_RX_1:
		ret = snd_soc_dai_set_sysclk(cpu_dai,
					     Q6AFE_LPASS_CLK_ID_TER_TDM_IBIT,
					     bclk, SNDRV_PCM_STREAM_PLAYBACK);
		if (ret)
			dev_err(cpu_dai->dev, "set TDM ibit clk %u failed: %d\n",
				bclk, ret);
		snd_soc_dai_set_fmt(cpu_dai, SND_SOC_DAIFMT_BP_FP);
		snd_soc_dai_set_fmt(codec_dai,
				     SND_SOC_DAIFMT_BC_FC | SND_SOC_DAIFMT_NB_NF |
				     SND_SOC_DAIFMT_DSP_A);
		break;
	default:
		break;
	}

	return 0;
}

static int venus_be_hw_params(struct snd_pcm_substream *substream,
			      struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
	struct snd_soc_component *comp;
	unsigned int bclk = params_rate(params) * tdm_slots * tdm_slot_width;
	int i, ret;

	/* TDM 槽位配置必须给 DSP：不给的话 AFE enable 会返回 -22（port 0x9020 无效参数） */
	ret = snd_soc_dai_set_tdm_slot(cpu_dai, 0, tdm_mask, tdm_slots,
				       tdm_slot_width);
	if (ret) {
		dev_err(cpu_dai->dev, "set_tdm_slot failed: %d\n", ret);
		return ret;
	}

	/* 厂商对 TERT TDM 也调 set_channel_map（槽位映射），DSP 侧要这份映射 */
	{
		unsigned int slots[4] = { 0, 4, 8, 12 };
		ret = snd_soc_dai_set_channel_map(cpu_dai, 0, NULL,
						  tdm_channels, slots);
		if (ret)
			dev_err(cpu_dai->dev, "set_channel_map failed: %d\n", ret);
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
	.startup = venus_be_startup,
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
