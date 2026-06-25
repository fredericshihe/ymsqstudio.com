-- TradingView 多周期趋势 JSON（webhook 写入，market-signal GET 读取覆盖展示分）
create table if not exists public.tv_mtf_signals (
  symbol_norm text primary key,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);
create index if not exists tv_mtf_signals_updated_at_idx on public.tv_mtf_signals (updated_at desc);
alter table public.tv_mtf_signals enable row level security;
-- 仅 service role（Edge Functions）通过服务密钥访问；匿名/用户不直连此表

comment on table public.tv_mtf_signals is 'TradingView alert: mtf_trend_score payload keyed by normalized symbol (e.g. BTCUSDT)';
