-- 禁用开发/测试阶段写入的弱兑换码，防止用户猜码免费使用。
-- 生产环境请通过管理后台「生成兑换码」功能生成随机强码。
UPDATE public.redeem_codes
SET active = false
WHERE code IN ('MB-DAY-2026', 'MB-WEEK-2026', 'MB-MONTH-2026');
