-- 同一根 K 线、同一方向只允许一条模拟开单；清理历史重复并加唯一约束，防止并发双插。

WITH mapping AS (
  SELECT
    id AS dup_id,
    MIN(id) OVER (PARTITION BY symbol, timeframe, entry_time, side) AS keep_id
  FROM public.sim_trades
)
UPDATE public.sim_positions p
SET source_trade_id = m.keep_id
FROM mapping m
WHERE p.source_trade_id = m.dup_id
  AND m.dup_id <> m.keep_id;
DELETE FROM public.sim_trades a
WHERE EXISTS (
  SELECT 1
  FROM public.sim_trades b
  WHERE b.symbol = a.symbol
    AND b.timeframe = a.timeframe
    AND b.entry_time = a.entry_time
    AND b.side = a.side
    AND b.id < a.id
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sim_trades_symbol_tf_entry_side
  ON public.sim_trades (symbol, timeframe, entry_time, side);
