# WorkManager 通过 Room 反射创建数据库，R8 必须保留实现类的无参构造器。
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}

# WorkManager 按类名反射创建输入合并器，Glance 更新任务也依赖其无参构造器。
-keep class * extends androidx.work.InputMerger {
    public <init>();
}

# PDFBox 的 JP2 解码器仅用于渲染图片，公告查找只读取文字层。
-dontwarn com.gemalto.jp2.JP2Decoder

# Apache POI（旧版 Word 预览）引用了 Android 上没有的类，只出现在调试输出、
# OSGi、图片渲染和 OOXML 等用不到的路径里。
-dontwarn java.awt.**
-dontwarn javax.imageio.**
-dontwarn javax.swing.**
-dontwarn javax.xml.stream.**
-dontwarn aQute.bnd.annotation.**
-dontwarn edu.umd.cs.findbugs.annotations.**
-dontwarn org.osgi.framework.**

# POI 内部按记录类型反射创建对象，裁剪后会在解析特定文档时才失败。
-keep class org.apache.poi.** { *; }
