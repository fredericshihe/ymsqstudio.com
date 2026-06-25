CREATE TABLE IF NOT EXISTS public.sim_positions (
  symbol text NOT NULL,
  timeframe text NOT NULL CHECK (timeframe IN ('15m', '1h', '4h', '1d')),
  side text NOT NULL CHECK (side IN ('long', 'short')),
  entry_price numeric NOT NULL,
  entry_time bigint NOT NULL,
  sl numeric NOT NULL,
  tp numeric NOT NULL,
  rr_at_entry numeric,
  source_trade_id bigint,
  last_processed_close_time bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (symbol, timeframe)
);
CREATE TABLE IF NOT EXISTS public.sim_trades (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  symbol text NOT NULL,
  timeframe text NOT NULL CHECK (timeframe IN ('15m', '1h', '4h', '1d')),
  side text NOT NULL CHECK (side IN ('long', 'short')),
  entry_price numeric NOT NULL,
  exit_price numeric,
  entry_time bigint NOT NULL,
  exit_time bigint,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  sl numeric NOT NULL,
  tp numeric NOT NULL,
  rr_at_entry numeric,
  pnl numeric,
  pnl_pct numeric,
  win boolean,
  open_reason text,
  close_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sim_positions
  DROP CONSTRAINT IF EXISTS sim_positions_source_trade_id_fkey;
ALTER TABLE public.sim_positions
  ADD CONSTRAINT sim_positions_source_trade_id_fkey
  FOREIGN KEY (source_trade_id) REFERENCES public.sim_trades (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_sim_trades_symbol_tf_status ON public.sim_trades (symbol, timeframe, status);
CREATE INDEX IF NOT EXISTS idx_sim_trades_symbol_tf_entry_time ON public.sim_trades (symbol, timeframe, entry_time DESC);
