-- redeem_codes：此前未启用 RLS，若项目在 Dashboard 中对该表开放 Data API，
-- 则 anon/authenticated 可能通过 PostgREST 直接 SELECT 出所有兑换码。
-- Edge Functions / RPC 使用 service_role，会绕过 RLS，行为不变。
ALTER TABLE public.redeem_codes ENABLE ROW LEVEL SECURITY;
-- 不创建任何 SELECT/INSERT/UPDATE/DELETE policy ⇒ 对受 RLS 约束的角色默认全部拒绝。
-- 仅 service_role（及表 owner 等）可访问；业务路径应继续走 Edge + redeem_access_code。;
