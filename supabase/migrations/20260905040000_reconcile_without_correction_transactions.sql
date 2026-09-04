BEGIN;

DO $function_patch$
DECLARE
  target_definition TEXT;
  updated_definition TEXT;
  block_start INTEGER;
  block_end INTEGER;
  block_length INTEGER;
BEGIN
  SELECT pg_get_functiondef('public.reconcile_weekly_coin_settlement(DATE)'::REGPROCEDURE)
  INTO target_definition;

  IF target_definition IS NULL THEN
    RAISE EXCEPTION '找不到 public.reconcile_weekly_coin_settlement(date)';
  END IF;

  block_start := POSITION(E'    INSERT INTO public.coin_transactions (\n      student_name,\n      amount,\n      balance_after,\n      reason,\n      transaction_type\n    ) VALUES (' IN target_definition);
  block_end := POSITION(E'    );\n  END LOOP;' IN target_definition);
  block_length := LENGTH(E'    );\n');

  IF block_start > 0 AND block_end > block_start THEN
    updated_definition := SUBSTRING(target_definition FROM 1 FOR block_start - 1)
      || SUBSTRING(target_definition FROM block_end + block_length);
  ELSE
    updated_definition := target_definition;
  END IF;

  updated_definition := REPLACE(
    updated_definition,
    E'  DELETE FROM public.weekly_coin_reward_detail\n  WHERE week_monday = v_monday;',
    E'  DELETE FROM public.coin_transactions\n'
    || E'  WHERE transaction_type IN (''auto_reward'', ''auto_penalty'')\n'
    || E'    AND reason LIKE ''【周榜结算】'' || TO_CHAR(v_monday + 4, ''YYYY年MM月DD日'') || ''当周%'';\n\n'
    || E'  DELETE FROM public.weekly_coin_reward_detail\n'
    || E'  WHERE week_monday = v_monday;'
  );

  IF updated_definition = target_definition
     OR updated_definition NOT LIKE '%DELETE FROM public.coin_transactions%'
     OR updated_definition LIKE '%settlement_correction%' THEN
    RAISE EXCEPTION '无法将重算函数改为直接替换周榜发放流水';
  END IF;

  EXECUTE updated_definition;
END;
$function_patch$;

COMMENT ON FUNCTION public.reconcile_weekly_coin_settlement(DATE) IS
'Rebuilds the final weekly settlement after auto-clear by deleting superseded weekly reward transactions and writing only the latest settlement records.';

NOTIFY pgrst, 'reload schema';

COMMIT;
