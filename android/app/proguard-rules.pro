# WorkManager 通过 Room 反射创建数据库，R8 必须保留实现类的无参构造器。
-keep class androidx.work.impl.WorkDatabase_Impl {
    public <init>();
}
