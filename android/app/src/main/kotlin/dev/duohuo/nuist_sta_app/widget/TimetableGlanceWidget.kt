/*
 * Copyright 2023 The Android Open Source Project
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * https://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package dev.duohuo.nuist_sta_app.widget

import android.content.Context
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 根据官方 Canonical LongTextAppWidget 的 Exact / provideContent / 数据流结构重写。
 * 布局与颜色按 NUIST++ 现有设计定制；2×2 卡片在实际宿主区域内保持正方形并居中。
 */
internal class TimetableGlanceWidget(private val square: Boolean) : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Exact
    override val stateDefinition = null

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val initial = withContext(Dispatchers.IO) { TimetableWidgetData.read(context) }
        provideContent {
            val snapshot by remember(context) { TimetableWidgetData.observe(context) }
                .collectAsState(initial = initial)
            TimetableWidgetContent(snapshot, square)
        }
    }
}
