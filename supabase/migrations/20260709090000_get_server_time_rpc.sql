-- get_server_time: 返回服务端当前时间，供前端校准客户端时钟偏移（修复 P2-16 时长显示因本地时钟偏差出错）
-- 前端 ServerTimeSync.syncWithServer() 会调用 rpc('get_server_time')；未部署时自动回退为连通性检测、偏移保持 0。
create or replace function public.get_server_time()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

-- 只读、无副作用，开放给匿名与登录角色执行
grant execute on function public.get_server_time() to anon, authenticated;
