-- 可选加固：为 student_database.name 增加唯一索引
--
-- 背景：该表历史上无 name 唯一约束，导致 .upsert(onConflict:'name') 报 42P10；
-- 前端已改为“先查再 insert/update”可在无约束下正常工作（见 index.html flushPending）。
-- 加上唯一索引后可从数据库层面：① 杜绝并发产生的重名重复行；② 让真正的 upsert 可用。
--
-- 前置条件：当前 name 无重复（截至 2026-07-09 共 214 行、全部唯一，已核对）。
-- 若存在重复会导致本迁移失败——下方 DO 块会先检测并给出明确报错，请先合并重名再执行。
--
-- ⚠️ 语义变化：加上唯一索引后，插入重名学生会被数据库拒绝（而非静默产生重复）。
--    这是期望行为；前端新增学生已有同名校验。

do $$
declare
  dup_count int;
begin
  select count(*) into dup_count
  from (
    select name from public.student_database group by name having count(*) > 1
  ) d;
  if dup_count > 0 then
    raise exception '存在 % 个重名，无法创建唯一索引；请先合并重名后再执行本迁移', dup_count;
  end if;
end$$;

create unique index if not exists student_database_name_key
  on public.student_database (name);
