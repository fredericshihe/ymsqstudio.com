-- 学生 AI 练琴分析缓存表
-- 在 Supabase SQL Editor 中执行此脚本

CREATE TABLE IF NOT EXISTS public.student_ai_analysis (
  id           bigserial PRIMARY KEY,
  student_name text        NOT NULL,
  analysis_text text       NOT NULL,
  model_source text,                          -- 'deepseek' | 'gemini-fallback'
  generated_at  timestamptz DEFAULT now(),
  CONSTRAINT student_ai_analysis_uq UNIQUE (student_name)
);

-- 索引加速按姓名查询
CREATE INDEX IF NOT EXISTS idx_ai_analysis_name ON public.student_ai_analysis (student_name);

-- 允许 anon / service_role 读写（与其他表权限保持一致）
ALTER TABLE public.student_ai_analysis ENABLE ROW LEVEL SECURITY;

CREATE POLICY "allow_all" ON public.student_ai_analysis
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.student_ai_analysis IS
  '每位学生的 AI 练琴状况分析缓存，默认 7 天有效，过期后 Dashboard 自动重新生成。';
