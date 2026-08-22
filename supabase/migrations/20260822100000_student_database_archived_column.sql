-- 学生库全屏重构：为批量归档功能提供落地字段
--
-- 背景：index.html 的 StudentLibrary 模块本地一直维护 archived 字段但从未真正
-- 写入/读取云端 student_database 表；menuhin-school-system/index.html 已经在
-- 生产库上成功 select/filter archived 字段，说明该表在生产环境已存在此列。
-- 本迁移是幂等的保险动作：确保该列一定存在，不会覆盖生产环境已有数据。
--
-- 语义：archived=true 表示该学生已从常规视图隐藏（软删除），但保留其在
-- practice_logs / student_coins / vw_student_coin_balances 等历史表中的记录，
-- 这些表/视图不按 archived 过滤，无需改动。

ALTER TABLE public.student_database
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false;
