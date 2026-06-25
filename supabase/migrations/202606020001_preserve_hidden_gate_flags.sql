-- Preserve permanent map-world progress when a later cloud snapshot is based on
-- stale client state. Item pickup ids were already protected in the RPCs; this
-- trigger makes the guard table-level as well, and adds hidden-zone flags.

CREATE OR REPLACE FUNCTION preserve_game_data_world_hidden_gate_flags(
  p_game_data JSONB,
  p_existing_game_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_world JSONB;
  v_flags JSONB;
  v_merged_hidden_flags JSONB;
BEGIN
  IF p_game_data IS NULL OR p_existing_game_data IS NULL THEN
    RETURN p_game_data;
  END IF;

  SELECT COALESCE(jsonb_object_agg(key, 'true'::JSONB ORDER BY key), '{}'::JSONB)
  INTO v_merged_hidden_flags
  FROM (
    SELECT DISTINCT key
    FROM (
      SELECT key, value
      FROM jsonb_each(
        CASE
          WHEN jsonb_typeof(p_game_data #> '{world,flags}') = 'object'
            THEN p_game_data #> '{world,flags}'
          ELSE '{}'::JSONB
        END
      )
      UNION ALL
      SELECT key, value
      FROM jsonb_each(
        CASE
          WHEN jsonb_typeof(p_existing_game_data #> '{world,flags}') = 'object'
            THEN p_existing_game_data #> '{world,flags}'
          ELSE '{}'::JSONB
        END
      )
    ) flag_source
    WHERE key <> ''
      AND (key LIKE 'hidden_gate:%' OR key LIKE '%:hidden_gate:%')
      AND value = 'true'::JSONB
  ) merged_hidden_keys;

  IF v_merged_hidden_flags = '{}'::JSONB
    AND jsonb_typeof(p_game_data #> '{world,flags}') IS DISTINCT FROM 'object'
    AND jsonb_typeof(p_existing_game_data #> '{world,flags}') IS DISTINCT FROM 'object' THEN
    RETURN p_game_data;
  END IF;

  v_world := CASE
    WHEN jsonb_typeof(p_game_data -> 'world') = 'object' THEN p_game_data -> 'world'
    ELSE '{}'::JSONB
  END;
  v_flags := CASE
    WHEN jsonb_typeof(v_world -> 'flags') = 'object' THEN v_world -> 'flags'
    ELSE '{}'::JSONB
  END;

  v_world := jsonb_set(v_world, '{flags}', v_flags || v_merged_hidden_flags, TRUE);
  RETURN jsonb_set(p_game_data, '{world}', v_world, TRUE);
END;
$$;
CREATE OR REPLACE FUNCTION preserve_game_data_world_trainer_victory_counts(
  p_game_data JSONB,
  p_existing_game_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_world JSONB;
  v_merged_trainer_counts JSONB;
BEGIN
  IF p_game_data IS NULL OR p_existing_game_data IS NULL THEN
    RETURN p_game_data;
  END IF;

  SELECT COALESCE(jsonb_object_agg(key, to_jsonb(count_value) ORDER BY key), '{}'::JSONB)
  INTO v_merged_trainer_counts
  FROM (
    SELECT key, MAX(count_value)::INT AS count_value
    FROM (
      SELECT key, LEAST(999, GREATEST(0, value::INT)) AS count_value
      FROM jsonb_each_text(
        CASE
          WHEN jsonb_typeof(p_game_data #> '{world,trainerVictoryCounts}') = 'object'
            THEN p_game_data #> '{world,trainerVictoryCounts}'
          ELSE '{}'::JSONB
        END
      )
      WHERE key <> '' AND value ~ '^[0-9]+$'
      UNION ALL
      SELECT key, LEAST(999, GREATEST(0, value::INT)) AS count_value
      FROM jsonb_each_text(
        CASE
          WHEN jsonb_typeof(p_existing_game_data #> '{world,trainerVictoryCounts}') = 'object'
            THEN p_existing_game_data #> '{world,trainerVictoryCounts}'
          ELSE '{}'::JSONB
        END
      )
      WHERE key <> '' AND value ~ '^[0-9]+$'
    ) trainer_count_source
    GROUP BY key
    HAVING MAX(count_value) > 0
  ) trainer_count_merged;

  IF v_merged_trainer_counts = '{}'::JSONB
    AND jsonb_typeof(p_game_data #> '{world,trainerVictoryCounts}') IS DISTINCT FROM 'object'
    AND jsonb_typeof(p_existing_game_data #> '{world,trainerVictoryCounts}') IS DISTINCT FROM 'object' THEN
    RETURN p_game_data;
  END IF;

  v_world := CASE
    WHEN jsonb_typeof(p_game_data -> 'world') = 'object' THEN p_game_data -> 'world'
    ELSE '{}'::JSONB
  END;

  v_world := jsonb_set(v_world, '{trainerVictoryCounts}', v_merged_trainer_counts, TRUE);
  RETURN jsonb_set(p_game_data, '{world}', v_world, TRUE);
END;
$$;
CREATE OR REPLACE FUNCTION preserve_game_save_monotonic_world_progress()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.game_data IS NOT NULL AND OLD.game_data IS NOT NULL THEN
    NEW.game_data := preserve_game_data_world_string_array(NEW.game_data, OLD.game_data, 'defeatedBossIds');
    NEW.game_data := preserve_game_data_world_string_array(NEW.game_data, OLD.game_data, 'defeatedTrainerIds');
    NEW.game_data := preserve_game_data_world_string_array(NEW.game_data, OLD.game_data, 'completedChallengeIds');
    NEW.game_data := preserve_game_data_world_string_array(NEW.game_data, OLD.game_data, 'collectedEventIds');
    NEW.game_data := preserve_game_data_world_trainer_victory_counts(NEW.game_data, OLD.game_data);
    NEW.game_data := preserve_game_data_world_hidden_gate_flags(NEW.game_data, OLD.game_data);
  END IF;

  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS preserve_game_save_monotonic_world_progress ON game_saves;
CREATE TRIGGER preserve_game_save_monotonic_world_progress
BEFORE UPDATE OF game_data ON game_saves
FOR EACH ROW
EXECUTE FUNCTION preserve_game_save_monotonic_world_progress();
NOTIFY pgrst, 'reload schema';
