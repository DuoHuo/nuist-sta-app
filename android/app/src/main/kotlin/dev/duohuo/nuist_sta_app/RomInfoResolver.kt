package dev.duohuo.nuist_sta_app

/** 已确认的厂商系统名称；版本未知时不借用 Android 或固件版本。 */
internal data class RomInfo(val name: String, val version: String?)

/** 固定属性的市场版本解析，不依赖厂商隐藏接口，也不返回原始构建字符串。 */
internal object RomInfoResolver {
    // 属性只作为兼容线索，不是厂商保证稳定的 API。先确定家族，再读取该家族版本。
    val propertyKeys = setOf(
        "ro.mi.os.version.name", "ro.mi.os.version.incremental", "ro.mi.os.version.code",
        "ro.miui.ui.version.name", "ro.miui.ui.version.code",
        "ro.product.anco.devicetype", "ro.sys.anco.product.software.version",
        "ro.product.os.dist.anco.apiversion", "hw_sc.build.platform.version",
        "ro.build.ohos.devicetype", "msc.config.magic.version", "ro.build.version.magic",
        "ro.build.version.emui", "ro.build.version.realmeui", "ro.oxygen.version",
        "ro.rom.version", "ro.build.version.oplusrom", "ro.build.version.oplusrom.confidential",
        "ro.build.version.opporom", "ro.build.display.id.show",
        "ro.vivo.os.build.display.id", "ro.build.version.oneui",
        "ro.flyme.published", "ro.flyme.version.id", "ro.build.display.id",
    )

    fun resolve(read: (String) -> String?, brand: String = ""): RomInfo? {
        val values = mutableMapOf<String, String?>()
        val cachedRead: (String) -> String? = { key ->
            if (values.containsKey(key)) values[key] else read(key).also { values[key] = it }
        }
        // 品牌只决定读取顺序，不代替属性证据；低性能设备先把本家族线索存入缓存。
        preferredKeys(brand).forEach { cachedRead(it) }
        return resolveKnown(cachedRead, brand)
    }

    private fun preferredKeys(brand: String): List<String> = when (brand.lowercase()) {
        "samsung" -> listOf("ro.build.version.oneui")
        "vivo", "iqoo" -> listOf("ro.vivo.os.build.display.id")
        "xiaomi", "redmi", "poco" -> listOf(
            "ro.mi.os.version.name", "ro.mi.os.version.code", "ro.mi.os.version.incremental",
            "ro.miui.ui.version.name", "ro.miui.ui.version.code",
        )
        "huawei" -> listOf(
            "ro.product.anco.devicetype", "ro.sys.anco.product.software.version",
            "ro.product.os.dist.anco.apiversion", "hw_sc.build.platform.version",
            "ro.build.ohos.devicetype", "ro.build.version.emui",
        )
        "honor" -> listOf("msc.config.magic.version", "ro.build.version.magic")
        "oppo" -> listOf(
            "ro.build.version.oplusrom", "ro.build.version.oplusrom.confidential", "ro.build.version.opporom",
        )
        "realme" -> listOf("ro.build.version.realmeui", "ro.build.version.oplusrom")
        "oneplus" -> listOf(
            "ro.oxygen.version", "ro.rom.version", "ro.build.version.oplusrom",
            "ro.build.version.oplusrom.confidential", "ro.build.version.opporom",
            "ro.build.display.id", "ro.build.display.id.show",
        )
        "meizu" -> listOf("ro.flyme.version.id", "ro.build.display.id", "ro.flyme.published")
        else -> emptyList()
    }

    private fun resolveKnown(read: (String) -> String?, brand: String): RomInfo? {
        // ANCO 是卓易通、出境易共用的 Android 兼容环境，优先于容器遗留的普通 ROM 属性。
        val ancoHostVersion = Regex(
            "^(?:[A-Za-z0-9][A-Za-z0-9_-]{0,63} +)?([1-9]\\d?\\.\\d{1,2}\\.\\d{1,2})" +
                "(?:\\.\\d{1,6})?(?:\\([A-Za-z0-9_-]{1,80}\\))?$",
        ).matchEntire(read("ro.sys.anco.product.software.version").orEmpty())?.groupValues?.get(1)
        val hasAncoDeviceType = !read("ro.product.anco.devicetype").isNullOrBlank()
        val hasAncoApi = Regex("^[1-9]\\d{0,7}$")
            .matches(read("ro.product.os.dist.anco.apiversion").orEmpty())
        if (hasAncoDeviceType || ancoHostVersion != null || hasAncoApi) {
            // API level 只用于确认环境，不能换算宿主版本；机型前缀与构建后缀也不返回。
            return RomInfo("HarmonyOSNEXT", ancoHostVersion)
        }

        val hyperName = read("ro.mi.os.version.name")
        val hyperCode = read("ro.mi.os.version.code")
        val hyperBuildVersion = Regex(
            "^OS(\\d{1,3}\\.\\d{1,3})(?:\\.\\d{1,3}){0,2}(?:\\.[A-Za-z0-9]+)?$",
            RegexOption.IGNORE_CASE,
        ).matchEntire(read("ro.mi.os.version.incremental").orEmpty())?.groupValues?.get(1)
        // 部分构建仅公开 incremental；只从明确的 OS 前缀提取市场主、次版本。
        if (hyperName != null || hyperCode != null || hyperBuildVersion != null) {
            val version = markedVersion(hyperName, "OS")
                ?: hyperBuildVersion
            return RomInfo("HyperOS", version)
        }
        val miuiName = read("ro.miui.ui.version.name")
        val miuiCode = read("ro.miui.ui.version.code")
        if (miuiName != null || miuiCode != null) {
            val match = Regex("^V(\\d{1,3})$", RegexOption.IGNORE_CASE).matchEntire(miuiName.orEmpty())
            val number = match?.groupValues?.get(1)
            val version = when {
                number == null -> null
                number.length == 3 -> "${number.toInt() / 10}.${number.toInt() % 10}"
                else -> number.toInt().toString()
            }
            return RomInfo("MIUI", version)
        }

        val harmonyVersion = numericVersion(read("hw_sc.build.platform.version"))
        if (harmonyVersion != null || read("ro.build.ohos.devicetype") != null) {
            return RomInfo("HarmonyOS", harmonyVersion)
        }
        val magicCurrent = numericVersion(read("msc.config.magic.version"))
        val magicLegacy = read("ro.build.version.magic")
        if (magicCurrent != null || magicLegacy != null) {
            val version = magicCurrent ?: markedVersion(magicLegacy, "MagicOS")
                ?: markedVersion(magicLegacy, "MagicUI") ?: numericVersion(magicLegacy)
            val name = when {
                magicCurrent != null -> if (magicCurrent.substringBefore('.').toInt() >= 7) "MagicOS" else "MagicUI"
                magicLegacy?.startsWith("MagicOS", ignoreCase = true) == true -> "MagicOS"
                magicLegacy?.startsWith("MagicUI", ignoreCase = true) == true -> "MagicUI"
                version != null -> if (version.substringBefore('.').toInt() >= 7) "MagicOS" else "MagicUI"
                else -> return null
            }
            return RomInfo(name, version)
        }
        val emui = read("ro.build.version.emui")
        if (emui?.startsWith("EmotionUI", ignoreCase = true) == true) {
            return RomInfo("EMUI", markedVersion(emui, "EmotionUI"))
        }

        val vivoDisplay = read("ro.vivo.os.build.display.id")
        if (vivoDisplay?.startsWith("OriginOS", ignoreCase = true) == true) {
            // Ocean 是市场代号，不能由 12.x 等固件构建号换算成数字版本。
            val version = if (vivoDisplay.equals("OriginOS Ocean", ignoreCase = true)) {
                "Ocean"
            } else markedVersion(vivoDisplay, "OriginOS")
            return RomInfo("OriginOS", version)
        }
        if (vivoDisplay?.startsWith("Funtouch", ignoreCase = true) == true) {
            return RomInfo("FuntouchOS", markedVersion(vivoDisplay, "Funtouch\\s*(?:OS|0S)?"))
        }

        val realme = read("ro.build.version.realmeui")
        if (realme != null) return RomInfo("realmeUI", numericVersion(realme))
        val oxygen = read("ro.oxygen.version")
        if (oxygen != null) return RomInfo("OxygenOS", numericVersion(oxygen))
        val hydrogen = read("ro.rom.version")
        if (hydrogen?.startsWith("H2OS", ignoreCase = true) == true) {
            return RomInfo("H2OS", markedVersion(hydrogen, "H2OS"))
        }
        val oplus = read("ro.build.version.oplusrom")
            ?: read("ro.build.version.oplusrom.confidential") ?: read("ro.build.version.opporom")
        if (oplus != null) {
            // realmeUI 的专有字段缺失时，不能把共享底座版本误报为 realmeUI 或 ColorOS。
            if (brand.equals("realme", ignoreCase = true)) return null
            // 一加海外系统也可能保留共享底座属性，不能仅凭品牌将它定为 ColorOS。
            if (brand.equals("oneplus", ignoreCase = true)) {
                val displays = listOfNotNull(read("ro.build.display.id"), read("ro.build.display.id.show"))
                displays.firstOrNull { it.startsWith("OxygenOS", ignoreCase = true) }?.let {
                    return RomInfo("OxygenOS", markedVersion(it, "OxygenOS"))
                }
                if (displays.any { it.startsWith("ColorOS", ignoreCase = true) || it.contains("(CN01)") }) {
                    return RomInfo("ColorOS", numericVersion(oplus))
                }
                return null
            }
            return RomInfo("ColorOS", numericVersion(oplus))
        }

        val oneUi = read("ro.build.version.oneui")
        if (oneUi != null) {
            val code = oneUi.takeIf { Regex("^\\d{5,7}$").matches(it) }?.toIntOrNull()
            val version = if (code != null && code / 10000 in 1..99) {
                // 低两位不总与市场补丁名一致，统计到主、次版本。
                "${code / 10000}.${code % 10000 / 100}"
            } else numericVersion(oneUi)
            return RomInfo("OneUI", version)
        }
        val flyme = read("ro.flyme.version.id")
        val display = read("ro.build.display.id")
        val publishedFlyme = read("ro.flyme.published") == "true"
        if (flyme?.startsWith("Flyme", ignoreCase = true) == true ||
            display?.startsWith("Flyme", ignoreCase = true) == true ||
            publishedFlyme) {
            // 有明确 Flyme 证据才接受专有版本字段的裸数字，优先使用用户可见的市场版本。
            val version = markedVersion(display, "Flyme") ?: markedVersion(flyme, "Flyme")
                ?: numericVersion(flyme)
            return RomInfo("Flyme", version)
        }
        return null
    }

    private fun numericVersion(raw: String?): String? =
        Regex("^[vV]?(\\d{1,3}(?:\\.\\d{1,3}){0,3})$")
            .matchEntire(raw.orEmpty())?.groupValues?.get(1)

    private fun markedVersion(raw: String?, marker: String): String? =
        Regex("^$marker[ _-]*[vV]?(\\d{1,3}(?:\\.\\d{1,3}){0,3})(?:[A-Za-z])?$", RegexOption.IGNORE_CASE)
            .matchEntire(raw.orEmpty())?.groupValues?.get(1)
}
