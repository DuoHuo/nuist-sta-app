# WorkManager 通过 Room 反射创建数据库，R8 必须保留实现类的无参构造器。
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}

# WorkManager 按类名反射创建输入合并器，Glance 更新任务也依赖其无参构造器。
-keep class * extends androidx.work.InputMerger {
    public <init>();
}
